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

    my ($lsf_queue, $lsf_resources);
    GetOptions(
        'lsf-queue=s'     => \$lsf_queue,
        'lsf-resources=s' => \$lsf_resources,
    ) or croak('Unable to parse parameters');

    $app->{argv} = [@ARGV];

    return ($lsf_queue, $lsf_resources);
}

sub load {
    my $class = shift;
    my $result = $class->SUPER::load(@_);
    return unless $result;
    my $p   = shift;
    my $app = $p->{app_prove};

    my ($lsf_queue, $lsf_resources) = $class->parse_lsf_options($app);

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
                '-PSlave',
                '--master-host', hostname,
                '--master-port', $TAP::Harness::Master::LISTEN_PORT,
                '--credentials', $self->{credentials}
            );
        }
    };

    return 1;
}

1;
