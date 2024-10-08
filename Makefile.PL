use lib '.';
use strict;
use warnings;

use inc::Module::Install;

# Definition.
abstract 'Base class and script for adding of book from NKC to Wikidata.';
author 'Michal Josef Spacek <skim@cpan.org>';
author_requires 'English' => 0;
author_requires 'File::Object' => 0.05;
author_requires 'Test::More' => 0;
author_requires 'Test::NoWarnings' => 0;
author_requires 'Test::Pod' => 0;
author_requires 'Test::Pod::Coverage' => 0;
install_script 'bin/nkc-to-wd';
license 'bsd';
name 'App-NKC2Wikidata';
perl_version 5.006;
readme_from 'bin/nkc-to-wd';
recursive_author_tests('xt');
requires 'Business::ISBN' => 0;
requires 'Encode' => 0;
requires 'English' => 0;
requires 'Error::Pure' => 0;
requires 'Getopt::Std' => 0;
requires 'MARC::Convert::Wikidata' => 0.16;
requires 'MARC::Record' => 0;
requires 'ZOOM' => 0;
requires 'WQS::SPARQL' => 0;
requires 'WQS::SPARQL::Query::Count' => 0;
requires 'WQS::SPARQL::Query::Select' => 0;
requires 'WQS::SPARQL::Result' => 0;
requires 'Wikibase::API' => 0.05;
requires 'Wikibase::Cache' => 0;
requires 'Wikibase::Datatype::Print::Item' => 0;
requires 'Wikidata::Reconcilation::AudioBook' => 0;
requires 'Wikidata::Reconcilation::BookSeries' => 0;
requires 'Wikidata::Reconcilation::Periodical' => 0;
requires 'Wikidata::Reconcilation::VersionEditionOrTranslation' => 0;
resources 'bugtracker' => 'https://github.com/michal-josef-spacek/App-NKC2Wikidata/issues',
resources 'homepage' => 'https://github.com/michal-josef-spacek/App-NKC2Wikidata';
resources 'repository' => 'git://github.com/michal-josef-spacek/App-NKC2Wikidata';
test_requires 'English' => 0;
test_requires 'File::Object' => 0;
test_requires 'File::Spec::Functions' => 0;
test_requires 'Test::More' => 0;
test_requires 'Test::NoWarnings' => 0;
test_requires 'Test::Output' => 0;
tests_recursive;
version '0.01';

# Run.
WriteAll();
