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
use Wikidata::Reconcilation::AudioBook;
use Wikidata::Reconcilation::BookSeries;
use Wikidata::Reconcilation::Periodical;
use Wikidata::Reconcilation::VersionEditionOrTranslation;

our $VERSION = 0.01;

$| = 1;

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
		'l' => $ENV{'WIKIDATA_LOGIN'},
		'p' => $ENV{'WIKIDATA_PASSWORD'},
		'v' => 0,
		'u' => 0,
	};
	if (! getopts('hl:p:uv', $self->{'_opts'}) || @ARGV < 1
		|| $self->{'_opts'}->{'h'}) {

		print STDERR "Usage: $0 [-h] [-l wikidata_login] [-p wikidata_password] ".
			"[-u] [-v] [--version] id_of_book\n";
		print STDERR "\t-h\t\t\tPrint help.\n";
		print STDERR "\t-l wikidata_login\tWikidata user name login.\n";
		print STDERR "\t-p wikidata_password\tWikidata user name password.\n";
		print STDERR "\t-u\t\t\tUpload (instead of print).\n";
		print STDERR "\t-v\t\t\tVerbose mode.\n";
		print STDERR "\t--version\t\tPrint version.\n";
		print STDERR "\tid_of_book\t\tIdentifier of book e.g. Czech ".
			"national bibliography id or ISBN".
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
		'callback_cover' => callback_cover($self),
		'callback_lang' => callback_lang($self),
		'callback_publisher_place' => callback_publisher_place($self),
		'callback_people' => callback_people($self),
		'callback_publisher_name' => callback_publisher_name($self),
		'callback_series' => callback_series($self),
		'marc_record' => $usmarc,
	);

	# Wikidata Query Service SPARQL connection instance.
	my $q = WQS::SPARQL->new;

	# Check if record exists on Wikidata.
	my @qids;
	if ($m2wd->type eq 'monograph') {
		my $r = Wikidata::Reconcilation::VersionEditionOrTranslation->new(
			'verbose' => $self->{'_opts'}->{'v'},
		);
		my %external_identifiers = ();
		foreach my $isbn (@{$m2wd->object->isbns}) {
			if ($isbn->type eq 13) {
				# TODO Multiple ISBNs.
				$external_identifiers{'P212'} = $isbn->isbn;
			} else {
				$external_identifiers{'P957'} = $isbn->isbn;
			}
		}
		if (defined $ccnb || defined $m2wd->object->ccnb) {
			$external_identifiers{'P3184'} = $ccnb || $m2wd->object->ccnb;
		}
		if (defined $m2wd->object->oclc) {
			$external_identifiers{'P243'} = $m2wd->object->oclc;
		}
		# TODO name, author, year, publisher
		@qids = $r->reconcile({'external_identifiers' => \%external_identifiers});
	} elsif ($m2wd->type eq 'audiobook') {
		my $r = Wikidata::Reconcilation::AudioBook->new(
			'verbose' => $self->{'_opts'}->{'v'},
		);
		my %external_identifiers = ();
		if (defined $ccnb || defined $m2wd->object->ccnb) {
			$external_identifiers{'P3184'} = $ccnb || $m2wd->object->ccnb;
		}
		# TODO name, author, year, publisher
		@qids = $r->reconcile({'external_identifiers' => \%external_identifiers});
	} elsif ($m2wd->type eq 'periodical') {
		my $r = Wikidata::Reconcilation::Periodical->new(
			'language' => 'cs',
			'verbose' => $self->{'_opts'}->{'v'},
		);
		my %external_identifiers = ();
		if (defined $ccnb || defined $m2wd->object->ccnb) {
			$external_identifiers{'P3184'} = $ccnb || $m2wd->object->ccnb;
		}
		if (defined $m2wd->object->issn) {
			$external_identifiers{'P236'} = $m2wd->object->issn;
		}
		# TODO author, publisher
		@qids = $r->reconcile({
			'external_identifiers' => \%external_identifiers,
			'identifiers' => {
				'end_time' => $m2wd->object->end_time,,
				'name' => $m2wd->object->title,
				'start_time' => $m2wd->object->start_time,
				# TODO Add to reconcile process.
				#'publishers' => ['TODO', 'TODO'],
			},
		});
	} else {
		err "Guess for '".$m2wd->type."' doesn't supported.";
	}
	if (@qids) {
		print "Found these QIDs:\n";
		print join "\n", @qids;
		print "\n";
		return 0;
	}

	my $item = $m2wd->wikidata;

	# Print object to output.
	if (! $self->{'_opts'}->{'u'}) {
		my $cache = Wikibase::Cache->new;
		my $wd_string = Wikibase::Datatype::Print::Item::print($item, {'cache' => $cache});
		print encode_utf8($wd_string)."\n";

	# Save to Wikidata
	} else {
		my $api = Wikibase::API->new(
			'login_name' => $self->{'_opts'}->{'l'},,
			'login_password' => $self->{'_opts'}->{'p'},
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
	my $self = shift;

	return sub {
		my $cover = shift;

		if ($cover eq 'hardback') {
			return 'Q193955';
		} elsif ($cover eq 'paperback') {
			return 'Q193934';
		}

		return;
	}
}

sub callback_lang {
	my $self = shift;

	return sub {
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
}

# XXX Rewrite to Wikidata::Reconcilation::People
sub callback_people {
	my $self = shift;

	return sub {
		my $people = shift;

		if (! defined $people->nkcr_aut) {
			my $people_name;
			if (defined $people->name) {
				$people_name .= $people->name;
			}
			if (defined $people->surname) {
				if (defined $people_name) {
					$people_name .= ' ';
				}
				$people_name .= $people->surname;
			}
			warn encode_utf8("People without NKCR AUT ID '".$people_name."' doesn't supported.")."\n";
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
}

# XXX Rewrite to Wikidata::Reconcilation::Publisher
sub callback_publisher_name {
	my $self = shift;

	return sub {
		my ($publisher, $year) = @_;

		my $publisher_name = $publisher->name;
		my ($sparql, $q, $ret_hr, $qid);

		# Look for publisher in official name and between years.
		if (defined $year) {
			my $sparql = <<"END";
SELECT DISTINCT ?item WHERE {
  ?item wdt:P31 wd:Q2085381.
  ?item wdt:P571 ?inception.
  ?item wdt:P576 ?dissolved.
  ?item wdt:P1448 '$publisher_name'\@cs.
  FILTER( ?inception <= "$year-31-12T00:00:00"^^xsd:dateTime )
  FILTER( ?dissolved >= "$year-01-01T00:00:00"^^xsd:dateTime )
}
END
			$q = WQS::SPARQL->new;
			$ret_hr = $q->query($sparql);
			($qid) = WQS::SPARQL::Result->new->result($ret_hr);
		}

		# Look for publisher in official name.
		if (! defined $qid) {
			$sparql = WQS::SPARQL::Query::Select->new->select_value({
				'P31' => 'Q2085381',
				'P1448' => $publisher->name,
			});
			$q = WQS::SPARQL->new;
			$ret_hr = $q->query($sparql);
			($qid) = WQS::SPARQL::Result->new->result($ret_hr);
		}

		# Look for publisher in label.
		if (! defined $qid) {
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
}

# XXX Rewrite to Wikidata::Reconcilation::Publisher
sub callback_publisher_place {
	my $self = shift;

	return sub {
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
}

sub callback_series {
	my $self = shift;

	return sub {
		my $series = shift;

		my $r = Wikidata::Reconcilation::BookSeries->new(
			'verbose' => $self->{'_opts'}->{'v'},
		);
		my @qids = $r->reconcile({
			'name' => $series->name,
			defined $series->publisher ? ('publisher' => $series->publisher->name) : (),
		});

		if (! @qids) {
			warn encode_utf8("Series '".$series->name."' doesn't exist in Wikidata.")."\n";
			return;
		}

		return $qids[0];
	}
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

L<Business::ISBN>,
L<Encode>,
L<Error::Pure>,
L<Getopt::Std>,
L<MARC::Convert::Wikidata>,
L<MARC::Record>,
L<ZOOM>,
L<WQS::SPARQL>,
L<WQS::SPARQL::Query::Count>,
L<WQS::SPARQL::Query::Select>,
L<WQS::SPARQL::Result>,
L<Wikibase::API>,
L<Wikibase::Cache>,
L<Wikibase::Datatype::Print::Item>.
L<Wikidata::Reconcilation::AudioBook>,
L<Wikidata::Reconcilation::BookSeries>,
L<Wikidata::Reconcilation::Periodical>,
L<Wikidata::Reconcilation::VersionEditionOrTranslation>

=head1 REPOSITORY

L<https://github.com/michal-josef-spacek/App-NKC2Wikidata>

=head1 AUTHOR

Michal Josef Špaček L<mailto:skim@cpan.org>

L<http://skim.cz>

=head1 LICENSE AND COPYRIGHT

© 2020-2023 Michal Josef Špaček

BSD 2-Clause License

=head1 VERSION

0.01

=cut
