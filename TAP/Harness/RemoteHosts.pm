package TAP::Harness::RemoteHosts;
use strict;
use vars qw($VERSION @ISA);
use TAP::Harness;
@ISA = qw(TAP::Harness);

=head1 NAME

TAP::Harness::RemoteHosts - Run tests across remote hosts similarly to TAP::Harness

=head1 VERSION

Version 0.01

=cut

$VERSION = '0.01';

=head1 DESCRIPTION

This is a simple test harness which allows tests to be run on remote hosts and
results automatically aggregated and output to STDOUT.

=head1 SYNOPSIS

 use TAP::Harness::RemoteHosts;
 my $harness = TAP::Harness::Hosts::LSF->new( \%args );
 $harness->runtests(@tests);

=cut

sub new {
    my ($class, @args) = @_;
    my $self = $class->SUPER::new(@args);
    $self->{multiplexer_class} = 'TAP::Parser::Multiplexer::RemoteHosts';
    return $self;
}

sub aggregate_tests {
    my ( $self, $aggregate, @tests ) = @_;

    my $jobs      = $self->jobs;
    my $scheduler = $self->make_scheduler(@tests);

    # #12458
    local $ENV{HARNESS_IS_VERBOSE} = 1
      if $self->formatter->verbosity > 0;

    # Formatter gets only names.
    $self->formatter->prepare( map { $_->description } $scheduler->get_all );

    my $jobs = $self->jobs;
    my $mux  = $self->_construct( $self->multiplexer_class );

    RESULT: {

        # Keep multiplexer topped up
        FILL:
        while ( $mux->parsers < $jobs ) {
            my $job = $scheduler->get_job;

            # If we hit a spinner stop filling and start running.
            last FILL if !defined $job || $job->is_spinner;

            $job->{host} = $mux->first_free_host;
            my ( $parser, $session ) = $self->make_parser($job);
            $mux->add( $parser, [ $session, $job ] );
        }

        if ( my ( $parser, $stash, $result ) = $mux->next ) {
            my ( $session, $job ) = @$stash;
            if ( defined $result ) {
                $session->result($result);
                $self->_bailout($result) if $result->is_bailout;
            }
            else {
                # End of parser. Automatically removed from the mux.
                $self->finish_parser( $parser, $session );
                $self->_after_test( $aggregate, $job, $parser );
                $job->finish;
            }
            redo RESULT;
        }
    }

    return;
}

sub _get_parser_args {
    my ($self, $job) = shift;
    my ($job) = @_;
    my $args = $self->SUPER::_get_parser_args(@_);
    my $source = $args->{source};
    if (!ref($source)) {
        if ($source !~ m{^[\\/]}) {
            $source = $ENV{PWD} . '/' . $source;
            $source =~ s{\\}{\/}g;
        }
        $args->{source} = 'ssh://' . $job->{host} . ':' . $source;
    }
    return $args;
}

1;

__END__
