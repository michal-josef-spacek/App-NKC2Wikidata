use strict;
use warnings;

use App::NKC2Wikidata;
use Test::More 'tests' => 2;
use Test::NoWarnings;

# Test.
is($App::NKC2Wikidata::VERSION, 0.09, 'Version.');
