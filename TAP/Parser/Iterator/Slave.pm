package TAP::Parser::Iterator::Slave;
use strict;
use IO::Select;
use Data::Dumper;
use vars (qw(@ISA $VERSION));
use TAP::Parser::Iterator;
@ISA = ('TAP::Parser::Iterator');

$VERSION = '0.01';

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
        die "Unknown arguments to TAP::Parser::Iterator::Slave";
    }

    $self->{wait} = 0;
    $self->{exit} = 0;

    $self->{socket}->print(
        "BEGIN\n" .
        Data::Dumper->new([$message], ['test'])->Dump .
        "END\n"
    );

    return bless($self, $class);
}

sub next_raw {
    my $self = shift;

    my $response = $self->{socket}->getline;

    if (!$response) {
        $self->{exit} = 1;
        return;
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
