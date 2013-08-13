use strict;

use FindBin qw($Bin);
use lib "$Bin/../lib";
use Test::More;

use_ok $_ for qw(
    Template::Twostep
);

done_testing;

