package TAP::Harness::RemoteHosts::LSF;
use strict;
use vars qw($VERSION @ISA);
use IPC::Open3;
use IO::Select;
use TAP::Harness::RemoteHosts;
@ISA = qw(TAP::Harness::RemoteHosts);

=head1 NAME

TAP::Harness::RemoteHosts::LSF - Run tests LSF hosts similarly to TAP::Harness

=head1 VERSION

Version 0.01

=cut

$VERSION = '0.01';

=head1 DESCRIPTION

This is a simple test harness which allows tests to be run on remote LSF hosts
and results automatically aggregated and output to STDOUT.

=head1 SYNOPSIS

 use TAP::Harness::RemoteHosts::LSF;
 my $harness = TAP::Harness::Hosts::LSF->new( \%args );
 $harness->runtests(@tests);

=cut

sub aggregate_tests {
    my $self = shift;

    # We are going to hold an interactive bsub connection open for the duration
    # of the tests, effectively reserving it.

    # First spawn all the bsubs in parallel
    print '# bsubbing';
    my @bsub_command   = (qw(bsub -q interactive -R), 'rusage[port3000=1,port4444=1]', qw(-Is /bin/bash));
    my $bsub_error;
    my @bsub_processes = map {
        my $bsub_process = {
            stdin  => IO::Handle->new,
            stdout => IO::Handle->new,
            stderr => IO::Handle->new,
        };
        $bsub_process->{pid} = open3(
            $bsub_process->{stdin},
            $bsub_process->{stdout},
            $bsub_process->{stderr},
            @bsub_command,
        );

        if ($@ && !$bsub_error) {
            $bsub_error = $@;
        }

        print '.';
        $bsub_process;
    } (1 .. $self->jobs);
    print "\n";

    if ($bsub_error) {
        for (@bsub_processes) { kill 9, $_->{pid}; }
        die "Could not execute (@bsub_command): $bsub_error";
    }

    # Next acquire the list of hosts
    for my $bsub_process (@bsub_processes) {
        $bsub_process->{stderr}->getline;  # Ignore the "Waiting for dispatch" line
        my $start_line = $bsub_process->{stderr}->getline;
        ($bsub_process->{host_name}) = $start_line =~ m{<Starting on ([^>]+)>};

        if (!$bsub_process->{host_name}) {
            for (@bsub_processes) { kill 9, $_->{pid}; }
            die "Unable to connect to an LSF host";
        }
        else {
            print '# Reserved ' . $bsub_process->{host_name} . "\n";
        }
    }
    $TAP::Parser::Multiplexer::RemoteHosts::ALL_HOSTS = [map {$_->{host_name}} @bsub_processes];

    my $result = $self->SUPER::aggregate_tests(@_);

    # Finally, we disconnect from the bsubbed hosts
    for my $bsub_process (@bsub_processes) {
        $bsub_process->{stdin}->print("exit\n");
    }

    return $result;
}

1;

__END__
