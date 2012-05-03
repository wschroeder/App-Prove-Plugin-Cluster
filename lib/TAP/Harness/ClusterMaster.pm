package TAP::Harness::ClusterMaster;
use strict;
use vars qw($VERSION @ISA);
use IO::Socket;
use IO::Select;
use TAP::Parser::ResultFactory;
use TAP::Parser::Iterator::ClusterSlave;
use TAP::Harness;
@ISA = qw(TAP::Harness);

=head1 NAME

TAP::Harness::ClusterMaster - Run tests across remote hosts with Slaves

=head1 VERSION

Version 0.01

=cut

$VERSION = '0.01';

=head1 DESCRIPTION

This is a simple test harness which allows tests to be run on remote hosts via
slaves and results automatically aggregated and output to STDOUT.

=head1 SYNOPSIS

 use TAP::Harness::ClusterMaster;
 my $harness = TAP::Harness::ClusterMaster->new( \%args );
 $harness->runtests(@tests);

=cut

our $COOKIE                          = 'cookie';
our $DEFAULT_SLAVE_STARTUP_CALLBACK  = sub {};
our $DEFAULT_SLAVE_TEARDOWN_CALLBACK = sub {};

sub new {
    my ($class, @args) = @_;
    my $self = $class->SUPER::new(@args);
    $self->{multiplexer_class} = 'TAP::Parser::Multiplexer::ClusterSockets';
    $self->{slave_startup_callback}  = $DEFAULT_SLAVE_STARTUP_CALLBACK;
    $self->{slave_teardown_callback} = $DEFAULT_SLAVE_TEARDOWN_CALLBACK;
    $self->{credentials}             = "$COOKIE - " . time;
    print STDERR "SLAVE CREDENTIALS: '" . $self->{credentials} . "'\n";
    return $self;
}

sub slave_startup_callback {
    my ($self, $new_callback) = @_;
    if ($new_callback) {
        $self->{slave_startup_callback} = $new_callback;
    }
    return $self->{slave_startup_callback};
}

sub slave_teardown_callback {
    my ($self, $new_callback) = @_;
    if ($new_callback) {
        $self->{slave_teardown_callback} = $new_callback;
    }
    return $self->{slave_teardown_callback};
}

sub start_listening_for_slaves {
    my ($self, $jobs) = @_;
    my $server;

    my $retry = 0;
    while (!$server and $retry++ < 5) {
        $server = IO::Socket::INET->new(
            Proto     => 'tcp',
            LocalPort => $TAP::Harness::ClusterMaster::LISTEN_PORT,
            Listen    => $jobs,
            ReuseAddr => 1,
            Timeout   => 0,
            Blocking  => 0
        );
    }

    if (!$server) {
        die "Unable to create server";
    }

    $self->{'master_listen_port'} = $server->sockport;

    return $server;
}

sub detect_new_slaves {
    my ($self, $server) = @_;
    my @new_connections = ();

    while (my $connection = $server->accept) {
        my $select = IO::Select->new($connection);
        my @ready_to_read = $select->can_read(3);

        # Connections should have responded by now
        if (@ready_to_read) {
            # This isn't perfect, but I want this to be simple and am choosing
            # this risk.  A client could connect and send data without a line
            # return.  That would cause us to hang here.  Also, they could send
            # us an extraordinarily huge amount of data on that first line,
            # which would result in a potential out-of-memory fault.  This is
            # the price of simplistic I/O.
            my $credentials = $connection->getline;
            $credentials =~ s/[\n\r]//g;

            # Only connections with the right credentials are accepted
            if ($credentials eq $self->{credentials}) {
                $connection->blocking(0);
                push @new_connections, $connection;
            }
        }
    }

    return @new_connections;
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

    my $server             = $self->start_listening_for_slaves($jobs);
    my $slave_startup_data = $self->slave_startup_callback->($self, $aggregate, @tests);

    $self->callback('after_runtests' => sub {
                        my $aggregate = shift;
                        $self->slave_teardown_callback->($self, $aggregate, $slave_startup_data)
                   });

    my @slaves;
    while (!(@slaves = $self->detect_new_slaves($server))) {
        sleep(1);
    }
    my $mux = $self->_construct($self->multiplexer_class, @slaves );
    my $time_of_last_update = time;

    RESULT: {
        if (time > $time_of_last_update + 60) {
            $time_of_last_update = time;
            print STDERR "Waiting for response from slaves with credentials " . $self->{credentials} . "\n";
        }

        # Add slave sockets to multiplexer
        if (@slaves < $jobs) {
            my @new_slaves = $self->detect_new_slaves($server);
            if (@new_slaves) {
                $mux->add_sockets(@new_slaves);
                push @slaves, @new_slaves;
            }
        }

        # Keep multiplexer topped up
        FILL:
        while ( $mux->parsers < @slaves ) {
            my $job = $scheduler->get_job;

            # If we hit a spinner stop filling and start running.
            last FILL if !defined $job || $job->is_spinner;

            $job->{socket} = $mux->first_free_socket;
            my ( $parser, $session ) = $self->make_parser($job);
            $mux->add( $parser, [ $session, $job ] );
        }

        my ( $parser, $stash, $result ) = $mux->next;
        if (defined($stash)) {
            my ( $session, $job ) = @$stash;
            if (defined $result && ref $result->raw && $result->raw == TAP::Parser::Iterator::ClusterSlave::SLAVE_DISCONNECTED) {
                $result = undef;
                @slaves = grep {$_ != $parser->{socket}} @slaves;
                $parser->exit(255);
                $session->result(
                    TAP::Parser::ResultFactory->make_result({
                        'type' => 'unknown',
                        'raw' => 'CRITICAL ERROR: Slave process disconnected prematurely!'
                    })
                );
            }
            if ( defined $result ) {
                if (
                    !(
                        ref $result->raw &&
                        (
                            $result->raw == TAP::Parser::Iterator::ClusterSlave::SLAVE_NOT_READY_FOR_READ ||
                            $result->raw == TAP::Parser::Iterator::ClusterSlave::SLAVE_DISCONNECTED
                        )
                     )
                ) {
                    $time_of_last_update = time;
                    $self->_do_with_autoflush_on( sub { $session->result($result) } );
                    $self->_bailout($result) if $result->is_bailout;
                }
            }
            else {
                # End of parser. Automatically removed from the mux.
                $time_of_last_update = time;
                $self->_do_with_autoflush_on( sub { $self->finish_parser( $parser, $session ) } );
                $self->_after_test( $aggregate, $job, $parser );
                $job->finish;
            }
            redo RESULT;
        }
    }

    return;
}

sub _do_with_autoflush_on {
    my($self, $sub) = @_;

    my $output_fh = $self->formatter->stdout;
    my $orig_autoflush = $|;
    my $orig_fh = select $output_fh;
    local $| = 1;
    select $orig_fh;

    &$sub;
}

sub _get_parser_args {
    my $self = shift;
    my ($job) = @_;
    my $args = $self->SUPER::_get_parser_args(@_);

    $args->{iterator} = TAP::Parser::Iterator::ClusterSlave->new(
        socket      => $job->{socket},
        credentials => $self->{credentials},
        source      => delete $args->{source},
        switches    => $args->{switches},
    );

    return $args;
}

1;

__END__
