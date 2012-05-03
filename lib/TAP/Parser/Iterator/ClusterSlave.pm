package TAP::Parser::Iterator::ClusterSlave;
use strict;
use IO::Select;
use Data::Dumper;
use Symbol 'gensym';
use vars (qw(@ISA $VERSION));
use TAP::Parser::Iterator;
@ISA = ('TAP::Parser::Iterator');

$VERSION = '0.01';

use constant SLAVE_NOT_READY_FOR_READ => gensym;
use constant SLAVE_DISCONNECTED       => gensym;

sub new {
    my $class = shift;
    my %args  = @_;

    my $self = $class->SUPER::new(@_);
    $self->{socket}      = delete $args{socket};
    $self->{credentials} = delete $args{credentials};

    my $message = {
        source   => delete $args{source},
        switches => delete $args{switches},
    };

    if (keys %args) {
        die "Unknown arguments to TAP::Parser::Iterator::ClusterSlave";
    }

    $self->{wait} = 0;
    $self->{exit} = 0;

    $self->{socket}->print(
        "BEGIN\n" .
        Data::Dumper->new([$message])->Terse(1)->Dump .
        "END\n"
    );

    return bless($self, $class);
}

sub next_raw {
    my $self = shift;

    my @ready = IO::Select->new($self->{socket})->can_read(0);
    my $response = $self->{socket}->getline;

    if (@ready && !$response) {
        $self->{exit} = 255;
        return SLAVE_DISCONNECTED;
    }

    if (!$response) {
        return SLAVE_NOT_READY_FOR_READ;
    }

    chomp($response);
    $response =~ s/[\n\r]//g;

    if ($response eq $self->{credentials}) {
        $self->{exit} = 0;
        return;
    }
    else {
        return $response;
    }
}

sub wait { shift->{wait} }
sub exit { shift->{exit} }

1;
