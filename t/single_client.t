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

        for my $test_number (1..10) {
            if ($test_number < 10) {
                $test_number = '0' . $test_number;
            }

            $socket->print("$credentials\n");

            like(get_message($socket), qr{\s*\{
\s*'source' => 't/fake_t/$test_number-test.t',
\s*'switches' => \[\]
\s*\}
}, "Received test message for $test_number-test.t");

            $socket->print("random junk\n");
            $socket->print("ok - Sample test\n");
            $socket->print("# more random junk\n");
            $socket->print("1..1\n");
        }

        $socket->print("$credentials\n");

        my @prove_results = $prove_stdout->getlines;
        my $last_line = pop @prove_results;
        is($last_line, "Result: PASS\n", 'All tests passed');

        my $wait_result = waitpid($prove_pid, 0);
        my $status = $?;
        is($wait_result, $prove_pid, 'prove finished on its own');
        is($status, 0, 'prove was successful');

        is(scalar(IO::Select->new($socket)->can_read), 1, 'A closed socket is readable');
        my $throwaway_buffer;
        is($socket->sysread($throwaway_buffer, 1000), 0, 'A socket properly closed by the server returns 0 bytes');

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
