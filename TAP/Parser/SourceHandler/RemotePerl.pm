package TAP::Parser::SourceHandler::RemotePerl;
use strict;
use vars qw($VERSION @ISA);
use Scalar::Util qw(blessed);
use Getopt::Long;
use TAP::Parser::IteratorFactory;
use TAP::Parser::Iterator::Process;
use TAP::Parser::SourceHandler::Perl;
@ISA = 'TAP::Parser::SourceHandler::Perl';

our $REMOTE_CALL = 'ssh';

TAP::Parser::IteratorFactory->register_handler( __PACKAGE__ );

sub host {
    my ($self, $host) = @_;
    if ($host) {
        $self->{host} = $host;
    }
    return $self->{host};
}

sub can_handle {
    my ($class, $source) = @_;
    return 0 unless $source->meta->{is_scalar};

    my $path_name = ${$source->raw};
    return 0 unless $path_name =~ m{^ssh://.+:.+};

    return 0.8 if $path_name =~ m{\.t$};    # vote higher than Executable
    return 0.9 if $path_name =~ m{\.pl$};

    return 0.75 if $path_name =~ m{\bt\b};    # vote higher than Executable

    # backwards compat, always vote:
    return 0.25;
}

sub make_iterator {
    my ( $class, $source ) = @_;

    # TODO: does this really need to be done here?
    $class->_autoflush_stdhandles;

    my ( $libs, $switches )
      = $class->_mangle_switches(
        $class->_filter_libs( $class->_switches($source) ) );

    $class->_run( $source, $libs, $switches );
}

sub _get_command_for_switches {
    my ( $class, $source, $switches ) = @_;
    my $perl_script_path = ${$source->raw};
    my ($host, $test_path) = $perl_script_path =~ m{^ssh://([^:]+):(.+)$};

    my @args    = @{ $source->test_args || [] };
    my $sub_command = 'cd ' . $ENV{PWD} . ' && ' . join(" ", $class->get_perl, @{$switches}, $test_path, @args);

    return (split(/ /, $REMOTE_CALL), $host, $sub_command);
}

1;

__END__
