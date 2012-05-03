use strict;
use warnings;
use Test::Most;
use App::Prove::Plugin::ClusterSlave;
use Try::Tiny;

# If this is set in the environment, it will interfere with this test.  Remove.
delete $ENV{PERL_TEST_HARNESS_DUMP_TAP};

dies_ok {
    App::Prove::Plugin::ClusterSlave->load({
        app_prove => {
            argv => [qw{ --master-host=localhost --master-port=12012 --credentials=meeger --lsf-startup=doesnt_exist }],
        },
    });
} 'Cannot execute what doesnt_exist';

dies_ok {
    App::Prove::Plugin::ClusterSlave->load({
        app_prove => {
            argv => [qw{ --master-host=localhost --master-port=12012 --credentials=meeger --lsf-startup=t/slave_startup_death/fail.sh }],
        },
    });
} 'Startup failed';

my $died;
try {
    App::Prove::Plugin::ClusterSlave->load({
        app_prove => {
            argv => [qw{ --master-host=localhost --master-port=12012 --credentials=meeger --lsf-startup=t/slave_startup_death/success.sh }],
        },
    });
}
catch {
    $died = 1;

    my $error_message = shift;
    like($error_message, qr{^Could not connect to master prove process}, 'Correct error message');
};

ok($died, 'Slave died as expected');

done_testing;
