use strict;
use warnings;
use Test::More;
use IO::Handle;
use IPC::Open3;
use IO::Socket;
use IO::Select;
use Try::Tiny;

# If this is set in the environment, it will interfere with this test.  Remove.
delete $ENV{PERL_TEST_HARNESS_DUMP_TAP};

sub get_message {
    my $socket = shift;
    is($socket->getline, "BEGIN\n", 'Saw BEGINning of message');

    my @lines;
    while (my $message_line = $socket->getline) {
        if ($message_line eq "END\n") {
            last;
        }
        push @lines, $message_line;
    }

    return join('', @lines);
}

my @prove_commands = (
    [qw(perl -I lib -S prove -v -PCluster --master-port 12012 -r t/fake_t/)],
    [qw(perl -I lib -S prove -v -PCluster --master-port 12012 --jobs 3 -r t/fake_t/)],
);
my $finished_rounds = 0;

for my $prove_command (@prove_commands) {
    my $prove_stdout = IO::Handle->new;
    my $prove_stderr = IO::Handle->new;
    my $prove_pid    = open3(undef, $prove_stdout, $prove_stderr, @$prove_command);

    try {
        my $credentials = $prove_stderr->getline;
        chomp($credentials);
        ($credentials) = $credentials =~ /^SLAVE CREDENTIALS: '(.*)'$/;

        like($credentials, qr{^cookie - \d+$}, 'validated credentials');

        my $socket;
        my $timeout = time + 3;

        while (!$socket && time < $timeout) {
            $socket = IO::Socket::INET->new(
                PeerAddr => 'localhost',
                PeerPort => 12012,
                Proto    => 'tcp',
            );
            if (!$socket) {
                sleep(0.5);
            }
        }
        ok($socket, 'Able to connect to server');

        $socket->print("$credentials\n");

        like(get_message($socket), qr{\s*\{
\s*'source' => 't/fake_t/\d+-test.t',
\s*'switches' => \[\]
\s*\}
}, "Received test message for (number)-test.t");

        for (1..30000) {
            $socket->print("random junk\n");
        }
        ok(1, "Sent 30000 lines");
        $socket->print("ok - Sample test\n");
        $socket->print("# more random junk\n");
        $socket->print("1..1\n");

        $socket->print("$credentials\n");

        # Wait for the parser to wrap up
        $prove_stdout->getline;

        # Then dump the pipe
        $prove_stdout->blocking(0);
        for (1..35000) {
            $prove_stdout->getline;
        }

        # Go back to getting the good stuff
        is($socket->getline, "BEGIN\n", 'master prove responds properly');
        $socket->close();
        kill 9, $prove_pid;

        $finished_rounds++;
    }
    catch {
        kill 9, $prove_pid;
        waitpid $prove_pid, 0;
        print STDERR shift;
    };
}

is($finished_rounds, scalar(@prove_commands), 'Finished all tests without perl dying');

done_testing;
