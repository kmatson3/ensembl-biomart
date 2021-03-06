use strict;
use warnings;
package Bio::EnsEMBL::BioMart::DatasetFactory;
use Bio::EnsEMBL::Hive::Utils qw/go_figure_dbc/;
use base ('Bio::EnsEMBL::Hive::RunnableDB::JobFactory');  # All Hive databases configuration files should inherit from HiveGeneric, directly or indirectly
use Data::Dumper;
use Bio::EnsEMBL::ApiVersion;

sub run {
    my $self = shift @_;
    # start a new session
    my $mart_dbc = Bio::EnsEMBL::DBSQL::DBConnection->new(
        -USER=>$self->param('user'),
        -PASS=>$self->param('pass'),
        -PORT=>$self->param('port'),
        -HOST=>$self->param('host'),
        -DBNAME=>$self->param('mart')
        );
    my $output_ids = [];
    if (scalar(@{$self->param('species')} != 0))
    {
      for my $species_name (@{$self->param('species')}){
           my $dataset_names = $mart_dbc->sql_helper()->execute(
          -SQL=>qq/select distinct(name),src_db,sql_name from dataset_names where sql_name=?/,
          -PARAMS => [$species_name]
                            )->[0];
          push @$output_ids, {dataset=>$dataset_names->[0],core=>$dataset_names->[1],species=>$dataset_names->[2]}
      }
    }
    else {
      for my $dataset_names (@{$mart_dbc->sql_helper()->execute(
          -SQL=>qq/select distinct(name),src_db,sql_name from dataset_names/
                            )}) {
          my ($dataset,$core,$species) = @$dataset_names;
          if ($self->param('mart') =~ m/mouse_mart/i and ($dataset eq "mmusculus" or $dataset eq "rnorvegicus")) {
            next;
          }
          elsif ($self->param('mart') =~ m/vb_gene_mart/i and $dataset eq "dmelanogaster_eg") {
            next;
          }
          push @$output_ids, {dataset=>$dataset,core=>$core,species=>$species}
      }
    }
    $self->param('output_ids',$output_ids);
    return;

}

sub write_output {
    my $self = shift @_;    
    my $output_ids = $self->param('output_ids');
    print "Writing output ids\n";
    $self->dataflow_output_id($output_ids, 1);
    $self->dataflow_output_id({}, 2);
    return 1;
}

1;
