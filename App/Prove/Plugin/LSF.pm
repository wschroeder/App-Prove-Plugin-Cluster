package App::Prove::Plugin::LSF;
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

    my ($remote_call);
    GetOptions(
        'remote_call=s' => \$remote_call,
    ) or croak('Unable to parse parameters');

    $app->{argv} = [@ARGV];

    $remote_call ||= 'ssh';
    return ($remote_call);
}

sub load {
    my ($class, $p) = @_;
    my $app  = $p->{app_prove};

    my ($remote_call) = $class->parse_additional_options($app);

    # This amazing hack is courtesy of the fact that App::Prove::_get_args does
    # not pass along argv and does not allow us to plugin more args than it
    # knows.
    $TAP::Parser::SourceHandler::RemotePerl::REMOTE_CALL = $remote_call;

    if (!defined($app->{jobs})) {
        $app->{jobs} = 1;
    }

    $app->require_harness('*' => 'TAP::Harness::RemoteHosts::LSF');

    return 1;
}

1;
