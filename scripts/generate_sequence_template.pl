#!/bin/env perl
# Copyright [2009-2014] EMBL-European Bioinformatics Institute
# 
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
# 
#      http://www.apache.org/licenses/LICENSE-2.0
# 
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.


# $Source$
# $Revision$
# $Date$
# $Author$
#
# Script to populate meta tables for partitioned marts from a set of crude XML templates

use warnings;
use strict;
use DBI;
use Data::Dumper;
use Carp;
use Log::Log4perl qw(:easy);
use DbiUtils;
use MartUtils;
use Cwd;
use Getopt::Long;
use Bio::EnsEMBL::Registry;

Log::Log4perl->easy_init($DEBUG);

my $division = '';

my $logger = get_logger();
my $e_release = undef;
my $release = undef;
my $species = undef;
my $registry = undef;
my $species_id_start = undef;
my $output_xml_dir = undef;
my $output_dir=undef;

my $mart_version = "0.7";

sub write_dataset_xml {
    my $dataset_names = shift;
    my $fname = "$output_dir/".$dataset_names->{dataset}.'.xml';
    open my $dataset_file, '>', $fname or croak "Could not open $fname for writing";
    my $template_file_name;
    if ($division eq "Ensembl"){
      $template_file_name = 'templates/dataset_sequence_template_ensembl.xml';
    }
    else {
      $template_file_name = 'templates/dataset_sequence_template.xml';
    }
    open my $template_file, '<', $template_file_name or croak "Could not open $template_file_name";
    while (my $line = <$template_file>) {
	$line =~ s/%name%/$$dataset_names{dataset}/g;
	$line =~ s/%id%/$$dataset_names{species_id}/g;
	$line =~ s/%des%/$$dataset_names{species_name}/g;
	$line =~ s/%version%/$$dataset_names{version_num}/g;
	$line =~ s/%species%/$$dataset_names{short_species_name}/g;
	$line =~ s/%release%/$release/g;
	print $dataset_file $line;
    }
    close($template_file);
    close($dataset_file);
    `gzip -c $fname > $fname.gz`;
    `md5sum $fname.gz > $fname.gz.md5`;}

sub write_replace_file {
    my ($template,$output,$datasets) = @_[0,1,2,3];
    open my $output_file, '>', $output or croak "Could not open $output";
    open my $template_file, '<', $template or croak "Could not open $template";
    while( my $line = <$template_file>) {
	$line =~ s/%name%/$datasets->{dataset}/g;
	$line =~ s/%id%/$datasets->{species_id}/g;
	$line =~ s/%des%/$datasets->{species_name}/g;
	$line =~ s/%version%/$datasets->{version_num}/g;
	$line =~ s/%species%/$datasets->{short_species_name}/g;
	$line =~ s/%release%/$release/g;

        print $output_file $line;
    }
    close($output_file);
    close($template_file);
}


sub write_template_xml {
    my $datasets = shift;
    my $datasets_text='';
    foreach my $dataset (@$datasets) {
	$datasets_text = $datasets_text .
	    '<DynamicDataset internalName="'.
	    $dataset->{dataset}.'"/>'."\n";
	my $template_filename = $dataset->{template};
        if ($division eq "Ensembl"){
	  write_replace_file('templates/sequence_template_template_ensembl.xml',"$output_dir/$template_filename",$dataset);
        }
        else{
          write_replace_file('templates/sequence_template_template.xml',"$output_dir/$template_filename",$dataset);
        }
	`gzip -c $output_dir/$template_filename > $output_dir/$template_filename.gz`;
    }
}

my $table_args ="ENGINE=MyISAM DEFAULT CHARSET=latin1";
sub create_metatable {
    my ($db_handle,$table_name,$cols) = @_[0,1,2];
    drop_and_create_table($db_handle,$table_name,$cols,$table_args);
}

sub write_metatables {
    my ($seq_mart_handle, $datasets_aref) = @_[0,1];
    my $pwd = &Cwd::cwd();

    $logger->info("Creating meta tables");

    # create tables
    create_metatable($seq_mart_handle,'meta_version__version__main',
		     ['version varchar(10) default NULL']);
    create_metatable($seq_mart_handle,'meta_template__xml__dm',
		     ['template varchar(100) default NULL',
		      'compressed_xml longblob',
		      'UNIQUE KEY template (template)']);
    create_metatable($seq_mart_handle,'meta_conf__xml__dm',
		     ['dataset_id_key int(11) NOT NULL',
		      'xml longblob',
		      'compressed_xml longblob',
		      'message_digest blob',
		      'UNIQUE KEY dataset_id_key (dataset_id_key)']);
    create_metatable($seq_mart_handle,'meta_conf__user__dm',
		     ['dataset_id_key int(11) default NULL',
		      'mart_user varchar(100) default NULL',
		      'UNIQUE KEY dataset_id_key (dataset_id_key,mart_user)']);
    create_metatable($seq_mart_handle,'meta_conf__interface__dm',
		     ['dataset_id_key int(11) default NULL',
		      'interface varchar(100) default NULL',
		      'UNIQUE KEY dataset_id_key (dataset_id_key,interface)']);
    create_metatable($seq_mart_handle,'meta_template__template__main',
		     ['dataset_id_key int(11) NOT NULL',
		      'template varchar(100) NOT NULL']);
    create_metatable($seq_mart_handle,'meta_conf__dataset__main',[
			 'dataset_id_key int(11) NOT NULL',
			 'dataset varchar(100) default NULL',
			 'display_name varchar(200) default NULL',
			 'description varchar(200) default NULL',
			 'type varchar(20) default NULL',
			 'visible int(1) unsigned default NULL',
			 'version varchar(25) default NULL',
			 'modified timestamp NOT NULL default CURRENT_TIMESTAMP on update CURRENT_TIMESTAMP',
			 'UNIQUE KEY dataset_id_key (dataset_id_key)']);

    $logger->info("Populating template tables");
    # populate template tables
    ## meta_version__version__main
    $seq_mart_handle->do("INSERT INTO meta_version__version__main VALUES ('$mart_version')");
    ## meta_template__xml__dm

    my $meta_conf__xml__dm_sth       = $seq_mart_handle->prepare('INSERT INTO meta_conf__xml__dm VALUES (?,?,?,?)');
    my $meta_conf__user__dm_sth      = $seq_mart_handle->prepare('INSERT INTO meta_conf__user__dm VALUES(?,\'default\')');
    my $meta_conf__interface__dm_sth = $seq_mart_handle->prepare('INSERT INTO meta_conf__interface__dm VALUES(?,\'default\')');
    my $meta_conf__dataset__main_sth = $seq_mart_handle->prepare("INSERT INTO meta_conf__dataset__main(dataset_id_key,dataset,display_name,description,type,visible,version) VALUES(?,?,?,'Ensembl Sequences','GenomicSequence',0,?)");
    my $meta_template__template__main_sth = $seq_mart_handle->prepare('INSERT INTO meta_template__template__main VALUES(?,?)');
    my $meta_template__xml__main_sth = $seq_mart_handle->prepare('INSERT INTO meta_template__xml__dm VALUES (?,?)');

    foreach my $dataset_href (@$datasets_aref) {

	my $template_filename = $dataset_href->{template};
	my $dataset_name      = $dataset_href->{dataset};

	my $compressed_template_path = "$output_dir/" . $template_filename . ".gz";

	if (! -f $compressed_template_path) {
	    die "Could not find compressed template file, $compressed_template_path!\n";
	}
	else {
	    $logger->info ("populating compressed template file, $template_filename.gz, into meta_template__xml__dm\n");
	}

	$meta_template__xml__main_sth->execute($dataset_href->{dataset}, file_to_bytes($compressed_template_path))
	    or croak "Could not load compressed template file, $compressed_template_path, into meta_template__xml__dm";

	$logger->info("Populating dataset tables");

    print Dumper $dataset_href;
	# meta_conf__xml__dm
	$meta_conf__xml__dm_sth->execute($dataset_href->{species_id},
				     file_to_bytes("$output_dir/$dataset_href->{dataset}.xml"),
				     file_to_bytes("$output_dir/$dataset_href->{dataset}.xml.gz"),
				     file_to_bytes("$output_dir/$dataset_href->{dataset}.xml.gz.md5")
				     ) or croak "Could not update meta_conf__xml__dm";
	# meta_conf__user__dm
	$meta_conf__user__dm_sth->execute($dataset_href->{species_id})
	    or croak "Could not update meta_conf__user__dm";

	# meta_conf__interface__dm
	$meta_conf__interface__dm_sth->execute($dataset_href->{species_id})
	    or croak "Could not update meta_conf__interface__dm";

	# meta_conf__dataset__main
	$meta_conf__dataset__main_sth->execute(
					   $dataset_href->{species_id},
					   "$dataset_href->{dataset}",
					   "$dataset_href->{species_name} sequences ($dataset_href->{version_num})",
					   $dataset_href->{version_num}) or croak "Could not update meta_conf__dataset__main";

	# meta_template__template__main
	$meta_template__template__main_sth->execute($dataset_href->{species_id},$dataset_name)
		or croak "Could not update meta_template__template__dm";
    }

    $meta_conf__xml__dm_sth->finish();
    $meta_conf__user__dm_sth->finish();
    $meta_conf__interface__dm_sth->finish();
    $meta_conf__dataset__main_sth->finish();
    $meta_template__template__main_sth->finish();
    $meta_template__xml__main_sth->finish();

    $logger->info("Population complete");
}

sub get_short_name {
    my ($db_name,$species_id) = @_;
    if (defined $species_id){
      uc(substr($db_name,0,3).$species_id);
    }
    else {
      uc(substr($db_name,0,3));
    }
}


# db params
my $db_host = "mysql-cluster-eg-prod-1.ebi.ac.uk";
my $db_port = 4238;
my $db_user = "ensrw";
my $db_pwd = "writ3rp1";

my $seq_mart_db;

sub usage {
    print "Usage: $0 -host <host> -port <port> -user <user> -pass|pwd <pwd> -seq_mart <target mart database> -release <release number> -registry <file> -species_id_start <species id number start> -output_xml_dir <dir location>\n";
    print "-host <host>\n";
    print "-port <port>\n";
    print "-user <host>\n";
    print "-pass|pwd <password>\n";
    print "-seq_mart <mart>\n";
    print "-release <ensembl release number>\n";
    print "-species <comma separated list of species names> (optional, used by VectorBase)\n";
    print "-registry <file> (optional, process only the entries in an Ensembl registry file)\n";
    print "-species_id_start <species id number start> (optional, start number for species_id, avoid duplicated numbers if the core databases are located on two servers. Default is 0)\n";
    print "-output_xml_dir <dir location> (optional, output directory location. Default is /tmp/seq_mart_output\n";
    exit 1;
};

my $options_okay = GetOptions (
    "host=s"=>\$db_host,
    "port=s"=>\$db_port,
    "user=s"=>\$db_user,
    "pass|pwd=s"=>\$db_pwd,
    "seq_mart=s"=>\$seq_mart_db,
    "release=s"=>\$e_release,
    "eg_release=s"=>\$release,
    "species=s"=>\$species,
    "registry=s" => \$registry,
    "species_id_start=s" => \$species_id_start,
    "output_xml_dir=s" => \$output_xml_dir,
    "help"=>sub {usage()}
    );

if(!$options_okay) {
    usage();
}

if (!defined $release) {
    print STDERR "no release argument given!\n";
    usage();
}

if (defined $output_xml_dir)
{
  $output_dir=$output_xml_dir;
}
else {
  $output_dir = "/tmp/seq_mart_output";
}

my $suffix = "_eg";
# Set the db_patterns, depending on the database mart name
if ($seq_mart_db =~ /bacteria/i) {
    $division = "EnsemblBacteria";
    $suffix = "";
}
elsif ($seq_mart_db =~ /protist/i) {
    $division = "EnsemblProtists";
}
elsif ($seq_mart_db =~ /fung/i) {
    $division = "EnsemblFungi";
}
elsif ($seq_mart_db =~ /plant/i) {
    $division = "EnsemblPlants";
}
elsif ($seq_mart_db =~ /metazoa/i) {
    $division = "EnsemblMetazoa";
}
elsif ($seq_mart_db =~ /vb/i) {
    $division = "EnsemblMetazoa";
} else {
    $division = "Ensembl";
    $suffix = "";
}

print STDERR "Set Ensembl division to '$division'\n";

print STDERR "working with EG release, $release, e! release $e_release\n";

if (! -d $output_dir) {
    print STDERR "create output directory, $output_dir\n";
    qx/mkdir $output_dir/;
}

my $seq_mart_string = "DBI:mysql:$seq_mart_db:$db_host:$db_port";
my $seq_mart_handle = DBI->connect($seq_mart_string, $db_user, $db_pwd,
				   { RaiseError => 1 }
    ) or croak "Could not connect to $seq_mart_string with user $db_user and pwd, $db_pwd";

# Use Registry rather than dataset_names table from gene mart
# to get the dataset name, the species id etc.

if( $registry ){

    unless( -f $registry ){ die "unable to locate registry file $registry\n" }
    Bio::EnsEMBL::Registry->load_all( $registry );
}
else{
    Bio::EnsEMBL::Registry->load_registry_from_db(
	-host => $db_host,
	-user => $db_user,
	-pass => $db_pwd,
	-port => $db_port,
	-db_version => $e_release);
}
#Bio::EnsEMBL::Registry->set_disconnect_when_inactive(1);

# Get all species for the given Ensembl division, or VectorBase
my $species_names_aref;
if ( defined $species ) {
    my @species = split /,/, $species;
    $species_names_aref = \@species;
}
else {
    $species_names_aref = get_all_species($division);
}

my @datasets = ();
my $i;
if (defined $species_id_start)
{
 $i=$species_id_start;
}
else{
  $i=0;
}
foreach my $species_name (@$species_names_aref) {

    $logger->info("Processing species, '$species_name'");

    # Filter out the species we don't in, if db_patterns array is defined

    my $dba = Bio::EnsEMBL::Registry->get_DBAdaptor($species_name, "core");

    my $core_dbname = $dba->dbc->dbname;

    my $meta_container =
	Bio::EnsEMBL::Registry->get_adaptor( "$species_name", 'Core', 'MetaContainer' );
    if (! defined $meta_container) {
        die "meta_container couldn't be instanciated for species, \"$species_name\"\n";
    }

    my $dataset_href = build_dataset_href ($meta_container,$logger,$suffix);
    if(!defined $dataset_href->{species_id} ||  $dataset_href->{species_id} =~ m/[^0-9]+/ ) {
	$dataset_href->{species_id} = ++$i;
    }
    push(@datasets,$dataset_href);
    write_dataset_xml($dataset_href);
    $dba->dbc()->disconnect_if_idle();
}

# 2. write template files
write_template_xml(\@datasets);

## 3. write and load metafiles

write_metatables($seq_mart_handle, \@datasets);

$seq_mart_handle->disconnect() or croak "Could not close handle to $seq_mart_string";

######

sub array_contains {
    my $array_ref = shift;
    my $element = shift;

    foreach my $item (@$array_ref) {
	if ($element  =~ /^$item/i) {
	    return 1;
	}
    }

    return 0;
}