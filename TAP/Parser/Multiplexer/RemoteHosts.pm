package TAP::Parser::Multiplexer::RemoteHosts;
use strict;
use TAP::Parser::Multiplexer;
use vars qw($VERSION @ISA);

@ISA = ('TAP::Parser::Multiplexer');
$VERSION = '0.01';

our $ALL_HOSTS = [];

sub new {
    my ($class, @args) = @_;
    my $self = $class->SUPER::new(@args);
    $self->initialize_hosts();
    return $self;
}

sub hosts {
    my ($self, $hosts) = @_;
    if ($hosts) {
        $self->{hosts} = $hosts;
    }
    return @{$self->{hosts}};
}

sub reserve_host {
    my ($self, $host) = @_;
    $self->hosts(
        [grep {$_ ne $host} $self->hosts]
    );
}

sub release_host {
    my ($self, $host) = @_;
    $self->hosts(
        [$self->hosts, $host]
    );
}

sub initialize_hosts {
    my $self = shift;
    $self->hosts($ALL_HOSTS);
}

sub first_free_host {
    my $self = shift;
    my ($host) = $self->hosts;
    return $host;
}

sub add {
    my $self = shift;
    my ($parser, $stash) = @_;
    my $result = $self->SUPER::add(@_);
    my $job = $stash->[1];
    $self->reserve_host($job->{host});
    $parser->{host} = $job->{host};  # TODO: Remove me when the source handler works properly
}

sub next {
    my $self = shift;
    my @results = $self->SUPER::next(@_);
    my ($parser) = @results;
    $self->release_host($parser->{host});
    return @results;
}

1;

__END__
