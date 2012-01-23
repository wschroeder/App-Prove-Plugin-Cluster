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

sub load {
    my $class = shift;
    my $result = $class->SUPER::load(@_);
    return unless $result;

    $TAP::Harness::Master::DEFAULT_SLAVE_STARTUP_CALLBACK = sub {
        my ($self, $aggregate, @tests) = @_;
        my $jobs = $self->jobs;
        for (1..$jobs) {
            open3(undef, undef, undef, qw(bsub -q short prove -PSlave --master-host), hostname, '--master-port', $TAP::Harness::Master::LISTEN_PORT, '--credentials', $self->{credentials});
        }
    };

    return 1;
}

1;
