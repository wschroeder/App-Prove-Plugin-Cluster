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

sub connect_to_master {
    my $timeout = time + 3;

    my $socket;
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

    return $socket;
}

sub send_test_results {
    my ($socket, $test_name, $credentials) = @_;
    $socket->print("random junk\n");
    $socket->print("ok 1 - $test_name\n");
    $socket->print("# more random junk\n");
    $socket->print("1..1\n");
    $socket->print("$credentials\n");
}

my $finished_rounds = 0;

my @scenarios = (qw(
    one_disconnect
    all_disconnect
));

my @prove_commands = (
    [qw(perl -I lib -S prove -v -PCluster --master-port 12012 --jobs 3 -r t/fake_t/)],
    [qw(perl -I lib -S prove -v -PCluster --master-port 12012 --jobs 4 -r t/fake_t/)],
);


for my $scenario (@scenarios) {
    for my $prove_command (@prove_commands) {
        my $prove_stdout = IO::Handle->new;
        my $prove_stderr = IO::Handle->new;
        my $prove_pid    = open3(undef, $prove_stdout, $prove_stderr, @$prove_command);

        try {
            my $credentials = $prove_stderr->getline;
            chomp($credentials);
            ($credentials) = $credentials =~ /^SLAVE CREDENTIALS: '(.*)'$/;

            like($credentials, qr{^cookie - \d+$}, 'validated credentials');

            my @sockets = map {
                my $socket = connect_to_master();
                ok($socket, 'Able to connect to server');
                $socket->print("$credentials\n");
                sleep(2);  # Give master a chance to start tests with just one of the sockets
                $socket;
            } (1..3);

            is(scalar(grep {$_} @sockets), 3, 'Connected exactly 3 clients');

            my $regex = qr{\s*\{
\s*'source' => 't/fake_t/(\d+)-test\.t',
\s*'switches' => \[\]
\s*\}};

            my @tests_found = ();

            my $get_test = sub {
                my $socket = shift;
                my $message = get_message($socket);
                like($message, $regex, "Received well-formed test message");
                my $test_number = ($message =~ $regex)[0];
                ok(!(grep {$test_number eq $_} @tests_found), "Found new test: $test_number");
                push @tests_found, $test_number;
            };

            for my $socket (@sockets) {
                $get_test->($socket);
            }

            diag("(1) Finishing sock0 and grabbing new test");
            send_test_results($sockets[0], 't4', $credentials);
            $get_test->($sockets[0]);
            diag("(2) Finishing sock0 again before other sockets and grabbing new test");
            send_test_results($sockets[0], 't5', $credentials);
            $get_test->($sockets[0]);
            diag("(3) Finishing sock2 and grabbing new test");
            send_test_results($sockets[2], 't6', $credentials);
            $get_test->($sockets[2]);
            diag("(4) Closing sock1 prematurely");
            $sockets[1]->close();
            diag("(5) Finishing sock0 and grabbing new test");
            send_test_results($sockets[0], 't7', $credentials);
            $get_test->($sockets[0]);

            if ($scenario eq 'one_disconnect') {
                diag("(6a) Finishing sock0 again and grabbing new test");
                send_test_results($sockets[0], 't8', $credentials);
                $get_test->($sockets[0]);
                diag("(7) Finishing sock2 and grabbing new test");
                send_test_results($sockets[2], 't9', $credentials);
                $get_test->($sockets[2]);
                diag("(8) Finishing sock0 and grabbing new test");
                send_test_results($sockets[0], 't10', $credentials);
                $get_test->($sockets[0]);
                diag("(9) Wrapping up all sockets");
                send_test_results($sockets[0], 't10', $credentials);
                send_test_results($sockets[2], 't9', $credentials);

            }
            else {
                diag("(6b) Closing all sockets");
                $sockets[0]->close();
                $sockets[2]->close();

            }

            my @prove_results = $prove_stdout->getlines;
            my $last_line = pop @prove_results;
            is($last_line, "Result: FAIL\n", 'We had at least one failure, thanks to our closed socket');

            my $wait_result = waitpid($prove_pid, 0);
            my $status = $?;
            is($wait_result, $prove_pid, 'prove finished on its own');
            is($status, 256, 'prove was a failure');

            if ($scenario eq 'one_disconnect') {
                for my $socket (@sockets[0,2]) {
                    is(scalar(IO::Select->new($socket)->can_read), 1, 'A closed socket is readable');
                    my $throwaway_buffer;
                    is($socket->sysread($throwaway_buffer, 1000), 0, 'A socket properly closed by the server returns 0 bytes');
                }
            }

            $finished_rounds++;
        }
        catch {
            kill 9, $prove_pid;
            waitpid $prove_pid, 0;
            print STDERR shift;
        };
    }
}

is($finished_rounds, scalar(@scenarios) * scalar(@prove_commands), 'Finished all tests without perl dying');

done_testing;
