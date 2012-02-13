package App::Prove::Plugin::Slave;
use strict;
use warnings;
use Getopt::Long;
use Carp;
use IO::Handle;
use IO::Socket;
use IO::Select;
use IPC::Open3;

sub parse_additional_options {
    my ($class, $app) = @_;

    my @args = @{$app->{argv}};
    local @ARGV = @args;
    Getopt::Long::Configure(qw(no_ignore_case bundling pass_through));

    my ($master_host, $master_port, $credentials, $lsf_startup, $lsf_teardown);
    GetOptions(
        'master-host=s'  => \$master_host,
        'master-port=s'  => \$master_port,
        'credentials=s'  => \$credentials,
        'lsf-startup=s'  => \$lsf_startup,
        'lsf-teardown=s' => \$lsf_teardown,
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

    return ($master_host, $master_port, $credentials, $lsf_startup, $lsf_teardown);
}

our $TEARDOWN_CALLBACK = sub {};

sub load {
    my ($class, $p) = @_;
    my $app  = $p->{app_prove};
    my ($master_host, $master_port, $credentials, $lsf_startup, $lsf_teardown) = $class->parse_additional_options($app);

    if ($lsf_startup) {
        if (system($lsf_startup) || $?) {
            die "Startup failed";
        }
    }
    if ($lsf_teardown) {
        $TEARDOWN_CALLBACK = sub { system($lsf_teardown) };
        for my $signal (qw(INT KILL ABRT)) {
            $SIG{$signal} = $TEARDOWN_CALLBACK;
        }
    }

    $class->run_client($master_host, $master_port, $credentials);
}

sub get_test {
    my ($class, $socket, $credentials) = @_;

    $socket->print("$credentials\n");

    my $begin_line = $socket->getline;

    # Master prove is finished
    if (!defined($begin_line)) {
        $TEARDOWN_CALLBACK->();
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
    my ($class, $master_host, $master_port, $credentials) = @_;
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
        my @switches     = @{$test_info->{switches}};
        my $stdout       = IO::Handle->new;
        my $stderr       = IO::Handle->new;
        my $pid          = open3(undef, $stdout, $stderr, 'perl', @switches, $test_source);
        my @lines;
        do {
            my @ready = IO::Select->new($stdout, $stderr)->can_read;
            @lines = grep {$_} map {$_->getline} @ready;
            if (@lines) {
                $socket->print(join('', grep {$_} @lines));
            }
        } while (@lines);
    }
}

1;
