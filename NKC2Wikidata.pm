package App::NKC2Wikidata;

use strict;
use warnings;

use Business::ISBN;
use Encode qw(decode_utf8 encode_utf8);
use Error::Pure qw(err);
use Getopt::Std;
use MARC::Convert::Wikidata;
use MARC::Record;
use ZOOM;
use WQS::SPARQL;
use WQS::SPARQL::Query::Count;
use WQS::SPARQL::Query::Select;
use WQS::SPARQL::Result;
use Wikibase::API;
use Wikibase::Cache;
use Wikibase::Datatype::Print::Item;

our $VERSION = 0.01;

# Constructor.
sub new {
	my ($class, @params) = @_;

	# Create object.
	my $self = bless {}, $class;

	# Object.
	return $self;
}

# Run.
sub run {
	my $self = shift;

	# Process arguments.
	$self->{'_opts'} = {
		'h' => 0,
		'u' => 0,
	};
	if (! getopts('hu', $self->{'_opts'}) || @ARGV < 1
		|| $self->{'_opts'}->{'h'}) {

		print STDERR "Usage: $0 [-h] [--version] id_of_book\n";
		print STDERR "\t-h\t\tPrint help.\n";
		print STDERR "\t-u\tUpload (instead of print).\n";
		print STDERR "\t--version\tPrint version.\n";
		print STDERR "\tid_of_book\tModule prefix. e.g. ".
			"Module::Install\n";
		return 1;
	}
	$self->{'_id_of_book'} = shift @ARGV;

	# Configuration of National library of the Czech Republic service.
	my $c = {
		host => 'aleph.nkp.cz',
		port => '9991',
		database => 'NKC01',
		record => 'usmarc'
	};

	# ZOOM object.
	my $conn = ZOOM::Connection->new(
		$c->{'host'}, $c->{'port'},
		'databaseName' => $c->{'database'},
	);
	$conn->option(preferredRecordSyntax => $c->{'record'});

	# Get MARC record from library.
	my ($rs, $ccnb);
	## CCNB
	if ($self->{'_id_of_book'} =~ m/^cnb\d+$/ms) {
		$rs = $conn->search_pqf('@attr 1=48 '.$self->{'_id_of_book'});
		if (! defined $rs || ! $rs->size) {
			print STDERR encode_utf8("Edition with ČČNB '$self->{'_id_of_book'}' doesn't exist.\n");
			return 1;
		}
		$ccnb = $self->{'_id_of_book'};
	## ISBN
	} else {
		$rs = $conn->search_pqf('@attr 1=7 '.$self->{'_id_of_book'});
		if (! defined $rs || ! $rs->size) {
			print STDERR "Edition with ISBN '$self->{'_id_of_book'}' doesn't exist.\n";
			return 1;
		}
	}
	my $raw_record = $rs->record(0)->raw;
	my $usmarc = MARC::Record->new_from_usmarc($raw_record);

	# Conversion instance for MARC to Wikidata conversion.
	my $m2wd = MARC::Convert::Wikidata->new(
		'callback_cover' => \&callback_cover,
		'callback_lang' => \&callback_lang,
		'callback_publisher_place' => \&callback_publisher_place,
		'callback_people' => \&callback_people,
		'callback_publisher_name' => \&callback_publisher_name,
		'callback_series' => \&callback_series,
		'marc_record' => $usmarc,
	);

	# Wikidata Query Service SPARQL connection instance.
	my $q = WQS::SPARQL->new;

	# Check if record exists.
	my @isbns;
	foreach my $isbn (@{$m2wd->object->isbns}) {
		if ($isbn->type eq 13) {
			push @isbns, 'P212', $isbn->isbn;
		} else {
			push @isbns, 'P957', $isbn->isbn;
		}
	}
	if (! defined $ccnb) {
		$ccnb = $m2wd->object->ccnb;
	}
	my $query_counts_hr = {
		defined $ccnb ? ('P3184' => $ccnb) : (),
		@isbns,
	};
	foreach my $property (keys %{$query_counts_hr}) {
		my $property_value = $query_counts_hr->{$property};
		my $sparql_count = WQS::SPARQL::Query::Count->new->count_value($property, $property_value);
		my $count = $q->query_count($sparql_count);
		if ($count) {
			print "Record with property '$property' and value '$property_value' exists.\n";
			return 0;
		}
	}

	# TODO Try to search book edition in Wikidata via author and name and year if exist
	# TODO Reconcilation?

	my $item = $m2wd->wikidata;

	# Print object to output.
	if (! $self->{'_opts'}->{'u'}) {
		my $cache = Wikibase::Cache->new;
		my $wd_string = Wikibase::Datatype::Print::Item::print($item, {'cache' => $cache});
		print encode_utf8($wd_string)."\n";

	# Save to Wikidata
	} else {
		my $api = Wikibase::API->new(
			'login_name' => 'Skim',
			'login_password' => 'Riejai0b',
			'mediawiki_site' => 'www.wikidata.org',
		);
		my $res = $api->create_item($item);

		if ($res->{'success'}) {
			my $id = $res->{'entity'}->{'id'};
			print "Item $id uploaded.\n";
		} else {
			print "Some error.\n";
		}
	}

	return 0;
}

sub callback_cover {
	my $cover = shift;

	if ($cover eq 'hardback') {
		return 'Q193955';
	} elsif ($cover eq 'paperback') {
		return 'Q193934';
	}

	return;
}

sub callback_lang {
	my $lang = shift;

	my $sparql = WQS::SPARQL::Query::Select->new->select_value({
		'P219' => $lang,
	});
	my $q = WQS::SPARQL->new;
	my $ret_hr = $q->query($sparql);
	my ($qid) = WQS::SPARQL::Result->new->result($ret_hr);

	if (! defined $qid) {
		warn encode_utf8("Language with bibliographic code '".$lang."' doesn't exist in Wikidata.")."\n";
		return;
	}

	return $qid->{'item'};
}

# XXX Rewrite to Wikidata::Reconcilation::People
sub callback_people {
	my $people = shift;

	if (! defined $people->nkcr_aut) {
		warn encode_utf8("People without NKCR AUT ID '".$people->name.' '.
			$people->surname."' doesn't supported.")."\n";
		return;
	}

	my $sparql = WQS::SPARQL::Query::Select->new->select_value({
		'P691' => $people->nkcr_aut,
	});
	my $q = WQS::SPARQL->new;
	my $ret_hr = $q->query($sparql);
	my ($qid) = WQS::SPARQL::Result->new->result($ret_hr);

	if (! defined $qid) {
		warn encode_utf8("People with NKCR AUT ID '".$people->nkcr_aut."' doesn't exist in Wikidata.")."\n";
		return;
	}

	return $qid->{'item'};
}

# XXX Rewrite to Wikidata::Reconcilation::Publisher
sub callback_publisher_name {
	my $publisher = shift;

	my $sparql = WQS::SPARQL::Query::Select->new->select_value({
		'P31' => 'Q2085381',
		'P1448' => $publisher->name,
	});
	my $q = WQS::SPARQL->new;
	my $ret_hr = $q->query($sparql);
	my ($qid) = WQS::SPARQL::Result->new->result($ret_hr);

	if (! defined $qid) {
		my $publisher_name = $publisher->name;
		$sparql = <<"END";
SELECT DISTINCT ?item WHERE {
  {
    ?item p:P31 ?stmt.
    ?stmt ps:P31 wd:Q2085381;
    wikibase:rank ?rank.
  } UNION {
    ?item p:P31 ?stmt.
    ?stmt ps:P31 wd:Q1320047;
    wikibase:rank ?rank.
  }
  FILTER(?rank != wikibase:DeprecatedRank)
  ?item (rdfs:label|skos:altLabel) ?label .
  FILTER(LANG(?label) = "cs").
  FILTER(STR(?label) = "$publisher_name")
}
END
		$ret_hr = $q->query($sparql);
		($qid) = WQS::SPARQL::Result->new->result($ret_hr);
	}

	if (! defined $qid) {
		warn encode_utf8("Publishing house '".$publisher->name."' doesn't exist in Wikidata.")."\n";
		return;
	}

	return $qid->{'item'};
}

# XXX Rewrite to Wikidata::Reconcilation::Publisher
sub callback_publisher_place {
	my $publisher = shift;

	my $sparql = WQS::SPARQL::Query::Select->new->select_value({
		'P31' => 'Q5153359',
		'P1705' => $publisher->place.'@cs',
	});
	my $q = WQS::SPARQL->new;
	my $ret_hr = $q->query($sparql);
	my ($qid) = WQS::SPARQL::Result->new->result($ret_hr);

	if (! defined $qid) {
		warn encode_utf8("Publishing house place '".$publisher->place."' doesn't exist in Wikidata.")."\n";
		return;
	}

	return $qid->{'item'};
}

sub callback_series {
	my $series = shift;

	my $series_name = $series->name;
	my $sparql = <<"END";
SELECT DISTINCT ?item WHERE {
  ?item p:P31 ?stmt.
  ?stmt ps:P31 wd:Q277759;
  wikibase:rank ?rank.
  FILTER(?rank != wikibase:DeprecatedRank)
  ?item (rdfs:label|skos:altLabel) ?label .
  FILTER(LANG(?label) = "cs").
  FILTER(STR(?label) = "$series_name")
}
END
	my $q = WQS::SPARQL->new;
	my $ret_hr = $q->query($sparql);
	my ($qid) = WQS::SPARQL::Result->new->result($ret_hr);

	if (! defined $qid) {
		warn encode_utf8("Series '".$series->name."' doesn't exist in Wikidata.")."\n";
		return;
	}

	return $qid->{'item'};
}

1;


__END__

=pod

=encoding utf8

=head1 NAME

App::NKC2Wikidata - Base class for nkc-to-wd script.

=head1 SYNOPSIS

 use App::NKC2Wikidata;

 my $app = App::NKC2Wikidata->new;
 my $exit_code = $app->run;

=head1 METHODS

=head2 C<new>

 my $app = App::NKC2Wikidata->new;

Constructor.

Returns instance of object.

=head2 C<run>

 my $exit_code = $app->run;

Run.

Returns 1 for error, 0 for success.

=head1 EXAMPLE

 use strict;
 use warnings;

 use App::NKC2Wikidata;

 # Arguments.
 @ARGV = (
         'Library',
 );

 # Run.
 exit App::NKC2Wikidata->new->run;

 # Output like:
 # TODO

=head1 DEPENDENCIES

L<Getopt::Std>.

=head1 REPOSITORY

L<https://github.com/michal-josef-spacek/App-NKC2Wikidata>

=head1 AUTHOR

Michal Josef Špaček L<mailto:skim@cpan.org>

L<http://skim.cz>

=head1 LICENSE AND COPYRIGHT

© 2020-2022 Michal Josef Špaček

BSD 2-Clause License

=head1 VERSION

0.01

=cut
