package App::Prove::Plugin::ClusterSlave;
use strict;
use warnings;
use Getopt::Long;
use Carp;
use IO::Handle;
use IO::Socket;
use IO::Select;
use IPC::Open3;
use Sys::Hostname;

our $TEARDOWN_CALLBACK = sub {};
our $TEARDOWN_IN_PROCESS_CALLBACK = sub {};

END {
    $TEARDOWN_CALLBACK->();
    $TEARDOWN_IN_PROCESS_CALLBACK->();
};

sub parse_additional_options {
    my ($class, $app) = @_;

    my @args = @{$app->{argv}};
    local @ARGV = @args;
    Getopt::Long::Configure(qw(no_ignore_case bundling pass_through));

    my ($master_host, $master_port, $credentials, $lsf_startup, $lsf_teardown, $lsf_startup_in_process, $lsf_teardown_in_process, $lsf_test_in_process);
    GetOptions(
        'master-host=s'             => \$master_host,
        'master-port=s'             => \$master_port,
        'credentials=s'             => \$credentials,
        'lsf-startup=s'             => \$lsf_startup,
        'lsf-teardown=s'            => \$lsf_teardown,
        'lsf-startup-in-process=s'  => \$lsf_startup_in_process,
        'lsf-teardown-in-process=s' => \$lsf_teardown_in_process,
        'lsf-test-in-process'       => \$lsf_test_in_process,
    ) or croak('Unable to parse parameters');

    $app->{argv} = [@ARGV];

    if (!defined($master_host)) {
        die "Did not specify --master-host";
    }
    if (!defined($master_port)) {
        die "Did not specify --master-port";
    }
    if (!defined($credentials)) {
        die "Did not specify --credentials";
    }

    return ($master_host, $master_port, $credentials, $lsf_startup, $lsf_teardown, $lsf_startup_in_process, $lsf_teardown_in_process, $lsf_test_in_process);
}

sub load {
    my ($class, $p) = @_;
    my $app  = $p->{app_prove};
    my ($master_host, $master_port, $credentials, $lsf_startup, $lsf_teardown, $lsf_startup_in_process, $lsf_teardown_in_process, $lsf_test_in_process) =
        $class->parse_additional_options($app);

    if ($lsf_teardown) {
        $TEARDOWN_CALLBACK = sub { system($lsf_teardown) };
    }
    if ($lsf_teardown_in_process) {
        $TEARDOWN_IN_PROCESS_CALLBACK = sub {
            $class->eval_perl_script_in_process($lsf_teardown_in_process);
        };
    }

    my @sigs = (qw(INT KILL ABRT TERM HUP STOP));
    local @SIG{@sigs} = map { sub { exit 1 } } @sigs;

    if ($lsf_startup) {
        if (system($lsf_startup) || $?) {
            die "Startup failed";
        }
    }

    if ($lsf_startup_in_process) {
        my $includes = $app->{includes};
        if ($includes) {
            $ENV{PERL5LIB} .= ':' . join ':', map {($_ =~ m{^/}) ? $_ : $ENV{PWD} . "/$_"} @$includes;
            push @INC, $class->includes($includes);
        }
        $class->eval_perl_script_in_process($lsf_startup_in_process);
    }

    $class->run_client($master_host, $master_port, $credentials, $lsf_test_in_process, $app->{includes}, ($app->{test_args} || []));
}

sub includes {
    my $class = shift;
    my $includes = (shift) || [];
    return map {($_ =~ m{^/}) ? $_ : $ENV{PWD} . "/$_"} @$includes;
}

sub eval_perl_script_in_process {
    my $class    = shift;
    my $job_info = shift;
    my $args     = shift;

    my $cwd = File::Spec->rel2abs('.');

    local $0 = $job_info;    #fixes FindBin (in English $0 means $PROGRAM_NAME)
    no strict;               # default for Perl5
    {

        package main;
        local @ARGV = $args ? @$args : ();
        do $0;               # do $0; could be enough for strict scripts
        chdir($cwd);

        if ($@) {
            die $@;
        }
    }
}

sub get_test {
    my ($class, $socket, $credentials) = @_;

    $socket->print("$credentials\n");

    my $begin_line = $socket->getline;

    # Master prove is finished
    if (!defined($begin_line)) {
        exit(0);
    }

    if ($begin_line ne "BEGIN\n") {
        die "Master prove sent unknown protocol message: $begin_line";
    }

    my @lines;
    while (my $message_line = $socket->getline) {
        if ($message_line eq "END\n") {
            last;
        }
        push @lines, $message_line;
    }

    my $raw_text = join('', @lines);
    return eval("$raw_text");
}

sub run_client {
    my ($class, $master_host, $master_port, $credentials, $test_in_process, $includes, $test_args) = @_;
    my $socket;
    my $timeout = time + 10;

    while (!$socket && time < $timeout) {
        $socket = IO::Socket::INET->new(
            PeerAddr => $master_host,
            PeerPort => $master_port,
            Proto    => 'tcp',
        );
        if (!$socket) {
            sleep(0.5);
        }
    }

    if (!$socket) {
        die "Could not connect to master prove process";
    }

    while (1) {
        my $test_info    = $class->get_test($socket, $credentials);
        my $test_source  = $test_info->{source};
        my $switches     = $test_info->{switches} || [];

        $socket->print('# Host: ' . hostname . "\n");

        if ($test_in_process) {
            # We need to fork because we want to create separate test plans within "the same process".
            # Do not close the socket!  We need the same socket to Master open.
            my $pid = fork();
            if ($pid) {
                waitpid( $pid, 0 );
            }
            else {
                eval {
                    # Redirect STDERR and STDOUT
                    local *STDERR = $socket;
                    local *STDOUT = $socket;

                    # Intercept all output from Test::More. Output all of them at once.
                    require Test::More;
                    my $builder = Test::More->builder;
                    $builder->output($socket);
                    $builder->failure_output($socket);
                    $builder->todo_output($socket);

                    $class->eval_perl_script_in_process($test_source, $test_args);
                };
                if ($@) {
                    $socket->print($@);
                    exit(1);
                }
                exit(0);
            }
        }
        else {
            my $pid = open3(undef, ">&".fileno($socket), undef, 'perl', @$switches, (map {('-I', $_)} $class->includes($includes)), $test_source, @$test_args);
            waitpid($pid, 0);
        }
    }
}

1;
