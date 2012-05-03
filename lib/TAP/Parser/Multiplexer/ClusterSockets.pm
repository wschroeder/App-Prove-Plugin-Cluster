package TAP::Parser::Multiplexer::ClusterSockets;
use strict;
use TAP::Parser::Iterator::ClusterSlave;
use TAP::Parser::Multiplexer;
use vars qw($VERSION @ISA);

@ISA = ('TAP::Parser::Multiplexer');
$VERSION = '0.01';

sub new {
    my ($class, @args) = @_;
    my $self = $class->SUPER::new(@args);
    $self->initialize_sockets(@args);
    return $self;
}

sub sockets {
    my ($self, $sockets) = @_;
    if ($sockets) {
        $self->{sockets} = $sockets;
    }
    return @{$self->{sockets}};
}

sub add_sockets {
    my ($self, @sockets) = @_;
    $self->sockets(
        [$self->sockets, @sockets]
    );
}

sub reserve_socket {
    my ($self, $socket) = @_;
    $self->sockets(
        [grep {$_ ne $socket} $self->sockets]
    );
}

sub release_socket {
    my ($self, $socket) = @_;
    $self->sockets(
        [$self->sockets, $socket]
    );
}

sub initialize_sockets {
    my ($self, @sockets) = @_;
    $self->sockets(scalar(@sockets) ? \@sockets : []);
}

sub first_free_socket {
    my $self = shift;
    my ($socket) = $self->sockets;
    return $socket;
}

sub add {
    my $self = shift;
    my ($parser, $stash) = @_;
    my $result = $self->SUPER::add(@_);
    my $job = $stash->[1];
    $self->reserve_socket($job->{socket});
    $parser->{socket} = $job->{socket};
}

sub next {
    my $self = shift;
    my $avid = $self->{avid};
    if (@$avid) {
        my ( $parser, $stash ) = @{ $avid->[0] };
        my $result = $parser->next;
        shift @$avid unless defined $result;
        if ($result && ref $result->raw && $result->raw == TAP::Parser::Iterator::ClusterSlave::SLAVE_NOT_READY_FOR_READ) {
            my $tail = shift @$avid;
            push @$avid, $tail;
        }
        elsif ($result && ref $result->raw && $result->raw == TAP::Parser::Iterator::ClusterSlave::SLAVE_DISCONNECTED) {
            shift @$avid;   # Drop the socket forever.
        }
        if (!defined($result)) {
            $self->release_socket($parser->{socket});
        }
        return ($parser, $stash, $result);
    }
}

1;

__END__
