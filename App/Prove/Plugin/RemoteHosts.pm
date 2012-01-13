package App::Prove::Plugin::RemoteHosts;
use strict;
use warnings;
use Getopt::Long;
use Carp;
use TAP::Parser::Multiplexer::RemoteHosts;
use TAP::Parser::SourceHandler::RemotePerl;

sub parse_additional_options {
    my ($class, $app) = @_;

    my @args = @{$app->{argv}};
    local @ARGV = @args;
    Getopt::Long::Configure(qw(no_ignore_case bundling pass_through));

    my ($hosts, $remote_call);
    GetOptions(
        'host=s@'       => \$hosts,
        'remote_call=s' => \$remote_call,
    ) or croak('Unable to parse parameters');

    $app->{argv} = [@ARGV];

    $hosts       ||= [];
    $remote_call ||= 'ssh';
    return ($hosts, $remote_call);
}

sub load {
    my ($class, $p) = @_;
    my $app  = $p->{app_prove};

    my ($hosts, $remote_call) = $class->parse_additional_options($app);
    if (!@$hosts) {
        return 1;
    }

    # This amazing hack is courtesy of the fact that App::Prove::_get_args does
    # not pass along argv and does not allow us to plugin more args than it
    # knows.
    $TAP::Parser::Multiplexer::RemoteHosts::ALL_HOSTS    = $hosts;
    $TAP::Parser::SourceHandler::RemotePerl::REMOTE_CALL = $remote_call;

    if (!defined($app->{jobs})) {
        $app->{jobs} = scalar(@$hosts) ? scalar(@$hosts) : 1;
    }

    $app->require_harness('*' => 'TAP::Harness::RemoteHosts');

    return 1;
}

1;
