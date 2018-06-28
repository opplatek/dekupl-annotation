package DEkupl::Analyzer::Annotations;
# ABSTRACT: Append annotation informations to contigs

use Moose;

use DEkupl::Utils;

with 'DEkupl::Analyzer';

# This is a object used to query annotations loaded into memory
has 'interval_query' => (
  is => 'ro',
  isa => 'DEkupl::IntervalQuery',
  required => 1,
);

# TODO This should be a hash to auto generate the documentation!
my @columns = (
  'gene_id',
  'gene_symbol',
  'gene_strand',
  'gene_biotype',
  'as_gene_id',
  'as_gene_symbol',
  'as_gene_strand',
  'as_gene_biotype',
  'upstream_gene_id',
  'upstream_gene_strand',
  'upstream_gene_symbol',
  'upstream_gene_dist',
  'downstream_gene_id',
  'downstream_gene_strand',
  'downstream_gene_symbol',
  'downstream_gene_dist',
  'exonic',
  'intronic',
);

sub BUILD {
  my $self = shift;

  my $contigs_it = $self->contigs_db->contigsIterator();

  while(my $contig = $contigs_it->()) {

    if($contig->{is_mapped}) {

      my ($fwd_results,$rv_results);
      my ($upstream_result, $upstream_dist, $downstream_result, $downstream_dist);

      my $query = DEkupl::GenomicInterval->new(
          chr => $contig->{chromosome},
          start => $contig->{start},
          end => $contig->{end},
      );

      if($self->is_stranded) {
        # Query annotations from contig strand
        $query->strand($contig->{strand});
        $fwd_results        = $self->interval_query->fetchByRegion($query);

        # If we have no results on the contig regions, we try to find the nearset neighbors.
        if(scalar @{$fwd_results} == 0) {
          ($upstream_result,$upstream_dist)   = $self->interval_query->fetchNearest5prim($query);
          ($downstream_result,$downstream_dist) = $self->interval_query->fetchNearest3prim($query);
        }
        
        # Set RV results with contig reverse strand
        $query->strand(DEkupl::Utils::reverseStrand($contig->{strand}));
        $rv_results = $self->interval_query->fetchByRegion($query);

      # else : unstranded case
      } else {
        # Add annotations on FWD strand
        $query->strand('+');
        $fwd_results = $self->interval_query->fetchByRegion($query);

        # Append annotations from RV strand
        $query->strand('-');
        push @{$fwd_results}, @{$self->interval_query->fetchByRegion($query)};

        # If we have no results on the contig regions, we try to find the nearset neighbors.
        if(scalar @{$fwd_results} == 0) {
          # Query forward strand
          $query->strand('+');
          my ($upstream_result_fwd, $upstream_dist_fwd) = $self->interval_query->_fetchNearestDown($query);
          my ($downstream_result_fwd, $downstream_dist_fwd) = $self->interval_query->_fetchNearestUp($query);

          # Query reverse strand
          $query->strand('-');
          my ($upstream_result_rv, $upstream_dist_rv) = $self->interval_query->_fetchNearestDown($query);
          my ($downstream_result_rv, $downstream_dist_rv) = $self->interval_query->_fetchNearestUp($query);

          # Select the closest 5prim gene between the two strand
          # If both are defined we choose the closest
          # Otherwise we chose the one that is defined
          if(defined $upstream_result_fwd && defined $upstream_result_rv) { 
            if($upstream_dist_fwd < $upstream_dist_rv) {
              ($upstream_result,$upstream_dist) = ($upstream_result_fwd, $upstream_dist_fwd);
            } else {
              ($upstream_result,$upstream_dist) = ($upstream_result_rv, $upstream_dist_rv);
            }
          } elsif(defined $upstream_result_fwd) {
            ($upstream_result,$upstream_dist) = ($upstream_result_fwd, $upstream_dist_fwd);
          } elsif(defined $upstream_result_rv) {
            ($upstream_result,$upstream_dist) = ($upstream_result_rv, $upstream_dist_rv);
          }
          
          # Select the closest 3prim gene between the two strand
          # If both are defined we choose the closest
          # Otherwise we chose the one that is defined
          if(defined $downstream_result_fwd && defined $downstream_result_rv) {
            if($downstream_dist_fwd < $downstream_dist_rv) {
              ($downstream_result,$downstream_dist) = ($downstream_result_fwd, $downstream_dist_fwd);
            } else {
              ($downstream_result,$downstream_dist) = ($downstream_result_rv, $downstream_dist_rv);
            }
          } elsif(defined $downstream_result_fwd) {
            ($downstream_result,$downstream_dist) = ($downstream_result_fwd, $downstream_dist_fwd);
          } elsif(defined $downstream_result_rv) {
            ($downstream_result,$downstream_dist) = ($downstream_result_rv, $downstream_dist_rv);
          }
        }

        # Set empty RV results
        $rv_results = [];
      }

      my $exonic = 0;
      my $intronic;

      foreach my $strand (('fwd','rv')) {
        my @results = $strand eq 'fwd'? @{$fwd_results} : @{$rv_results};

        foreach my $res (@results) {
          my $res_type = ref($res);

          # TODO we should do a special treatment when there is multiple genes overlapping
          # the position. Usually we should choose the one that is 'protein_coding' over
          # a non_conding gene!
          if($res_type eq 'DEkupl::Annotations::Gene') {
            if($strand eq 'fwd') {
              $contig->{gene_id} = $res->id;
              $contig->{gene_strand} = $res->strand;
              $contig->{gene_symbol} = $res->symbol;
              $contig->{gene_biotype} = $res->biotype;
            } elsif($strand eq '5prim') {
              $contig->{as_gene_id} = $res->id;
              $contig->{as_gene_strand} = $res->strand;
              $contig->{as_gene_symbol} = $res->symbol;
              $contig->{as_gene_biotype} = $res->biotype;
            }
          } elsif($res_type eq 'DEkupl::Annotations::Exon') {
            $exonic = 1;
            # The contig overlap the exon and the intron
            if ($query->start < $res->start || $query->end > $res->end) {
              $intronic = 1;
            } elsif(!defined $intronic) {
              $intronic = 0;
            }
          }
        }
      }

      $intronic = 1 if !defined $intronic; # We have found no exons, therefor we are fully intronic.

      $contig->{exonic}   = DEkupl::Utils::booleanEncoding($exonic);
      $contig->{intronic} = DEkupl::Utils::booleanEncoding($intronic);

      # Set 5prim annotations
      if(defined $upstream_result) {
        # If we have match an exon, we get the gene object
        if(ref($upstream_result) eq 'DEkupl::Annotations::Exon') {
          $upstream_result = $upstream_result->gene;
        }
        $contig->{'upstream_gene_id'}     = $upstream_result->id;
        $contig->{'upstream_gene_strand'} = $upstream_result->strand;
        $contig->{'upstream_gene_symbol'} = $upstream_result->symbol;
        $contig->{'upstream_gene_dist'}   = $upstream_dist;
      }

      # Set 3prim annotations
      if(defined $downstream_result) {
        # If we have match an exon, we get the gene object
        if(ref($downstream_result) eq 'DEkupl::Annotations::Exon') {
          $downstream_result = $downstream_result->gene;
        }
        $contig->{'downstream_gene_id'}     = $downstream_result->id;
        $contig->{'downstream_gene_strand'} = $downstream_result->strand;
        $contig->{'downstream_gene_symbol'} = $downstream_result->symbol;
        $contig->{'downstream_gene_dist'}   = $downstream_dist;
      }

      # Save contig
      $self->contigs_db->saveContig($contig);
    }
  }
}


sub getHeaders {
  my $self = shift;
  return @columns;
}

sub getValues {
  my $self = shift;
  my $contig = shift;
  my @values = map { defined $contig->{$_}? $contig->{$_} : $DEkupl::Utils::NA_value } @columns;
  return @values;
}

no Moose;
__PACKAGE__->meta->make_immutable;