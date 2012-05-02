package App::Prove::Plugin::ClusterLSF;
use strict;
use warnings;
use Getopt::Long;
use Carp;
use TAP::Harness::Master;
use IPC::Open3;
use Sys::Hostname;
use App::Prove::Plugin::Cluster;
use vars (qw(@ISA));
@ISA = ('App::Prove::Plugin::Cluster');

sub parse_lsf_options {
    my ($class, $app) = @_;

    my @args = @{$app->{argv}};
    local @ARGV = @args;
    Getopt::Long::Configure(qw(no_ignore_case bundling pass_through));

    my ($lsf_queue, $lsf_resources, $lsf_startup, $lsf_teardown, $lsf_startup_in_process, $lsf_teardown_in_process, $lsf_test_in_process);
    GetOptions(
        'lsf-queue=s'               => \$lsf_queue,
        'lsf-resources=s'           => \$lsf_resources,
        'lsf-startup=s'             => \$lsf_startup,
        'lsf-teardown=s'            => \$lsf_teardown,
        'lsf-startup-in-process=s'  => \$lsf_startup_in_process,
        'lsf-teardown-in-process=s' => \$lsf_teardown_in_process,
        'lsf-test-in-process'       => \$lsf_test_in_process,
    ) or croak('Unable to parse parameters');

    $app->{argv} = [@ARGV];

    if ($lsf_startup_in_process && !-e $lsf_startup_in_process) {
        die "File specified in --lsf-startup-in-process ($lsf_startup_in_process) does not exist";
    }

    if ($lsf_teardown_in_process && !-e $lsf_teardown_in_process) {
        die "File specified in --lsf-teardown-in-process ($lsf_teardown_in_process) does not exist";
    }

    return ($lsf_queue, $lsf_resources, $lsf_startup, $lsf_teardown, $lsf_startup_in_process, $lsf_teardown_in_process, $lsf_test_in_process);
}

sub load {
    my $class = shift;
    my $result = $class->SUPER::load(@_);
    return unless $result;
    my $p   = shift;
    my $app = $p->{app_prove};

    my ($lsf_queue, $lsf_resources, $lsf_startup, $lsf_teardown, $lsf_startup_in_process, $lsf_teardown_in_process, $lsf_test_in_process) =
        $class->parse_lsf_options($app);

    my $includes  = $app->{includes};
    my $test_args = $app->{test_args};

    $TAP::Harness::Master::DEFAULT_SLAVE_STARTUP_CALLBACK = sub {
        my ($self, $aggregate, @tests) = @_;
        my $jobs = $self->jobs;
        for (1..$jobs) {
            open3(
                undef, undef, undef,  # std pipes
                'bsub',               # command
                ($lsf_queue     ? ('-q', $lsf_queue)     : ()),
                ($lsf_resources ? ('-R', $lsf_resources) : ()),
                'prove',
                ($includes               ? (map {('-I', $_)} @$includes) : ()),
                '-PSlave',
                '--master-host', hostname,
                '--master-port', $TAP::Harness::Master::LISTEN_PORT,
                ($lsf_startup             ? ('--lsf-startup',             $lsf_startup)  : ()),
                ($lsf_teardown            ? ('--lsf-teardown',            $lsf_teardown) : ()),
                ($lsf_startup_in_process  ? ('--lsf-startup-in-process',  $lsf_startup_in_process)  : ()),
                ($lsf_teardown_in_process ? ('--lsf-teardown-in-process', $lsf_teardown_in_process) : ()),
                ($lsf_test_in_process     ? '--lsf-test-in-process' : ()),
                '--credentials', $self->{credentials},
                (@$test_args              ? ('::', @$test_args) : ()),
            );
        }
    };

    return 1;
}

1;
