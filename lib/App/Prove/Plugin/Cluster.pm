package App::Prove::Plugin::Cluster;
use strict;
use warnings;
use Getopt::Long;
use Carp;
use TAP::Harness::ClusterMaster;

sub parse_additional_options {
    my ($class, $app) = @_;

    my @args = @{$app->{argv}};
    local @ARGV = @args;
    Getopt::Long::Configure(qw(no_ignore_case bundling pass_through));

    my ($master_port, $cookie);
    GetOptions(
        'master-port=s' => \$master_port,
        'cookie=s'      => \$cookie,
    ) or croak('Unable to parse parameters');

    $app->{argv} = [@ARGV];

    return ($master_port, $cookie);
}

sub load {
    my ($class, $p) = @_;
    my $app  = $p->{app_prove};

    my ($master_port, $cookie) = $class->parse_additional_options($app);

    if (!defined($app->{jobs})) {
        $app->{jobs} = 1;
    }

    if ($master_port) {
        # The user wanted to manually specify a port instead of letting the system pick one
        $TAP::Harness::ClusterMaster::LISTEN_PORT = $master_port;
    }
    if ($cookie) {
        $TAP::Harness::ClusterMaster::COOKIE = $cookie;
    }

    $app->require_harness('*' => 'TAP::Harness::ClusterMaster');

    return 1;
}

1;
