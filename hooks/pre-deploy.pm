#!/usr/bin/env perl
# vim: set ts=2 sw=2 sts=2 foldmethod=marker
package Genesis::Hook::PreDeploy::Vault v4.0.0;

use strict;
use warnings;
use v5.20; # Genesis min perl version is 5.20
use Genesis qw/bail info run/;
use parent qw(Genesis::Hook);
use lib $ENV{GENESIS_LIB} // "$ENV{HOME}/.genesis/lib";
use File::Basename qw/dirname/;
use File::Path qw/make_path/;

sub init {
  my ($class, %ops) = @_;
  my $obj = $class->SUPER::init(%ops);
  $obj->check_minimum_genesis_version('3.1.0-rc.20');
  return $obj;
}

sub perform {
  my ($self) = @_;
  my $env = $self->env;
  my $datafile = $ENV{GENESIS_PREDEPLOY_DATAFILE};

  # Ensure datafile directory exists
  make_path(dirname($datafile)) unless -d dirname($datafile);

  # Try to get vault access for this environment
  # This will return undef if vault doesn't exist yet (first deployment)
  my $vault = $env->vault;
  
  if ($vault) {
    # Check if vault seal keys exist
    if ($vault->has("secret/vault/seal/keys")) {
      # Try to retrieve vault seal keys
      eval {
        my $seal_data = $vault->get("secret/vault/seal/keys");
        
        open my $fh, '>', $datafile or bail("Cannot open $datafile for writing: $!");
        
        # Write each key to the datafile
        for (my $i = 1; $i <= 3; $i++) {
          my $key_name = "key$i";
          if (exists $seal_data->{$key_name} && defined $seal_data->{$key_name}) {
            print $fh $seal_data->{$key_name} . "\n";
          }
        }
        
        close $fh;
      };
      
      # If we encountered any errors, remove the datafile
      if ($@) {
        unlink $datafile if -e $datafile;
        info("Unable to retrieve seal keys: $@");
      }
      
      # Remove empty datafile
      if (-e $datafile && -z $datafile) {
        unlink $datafile;
      }
    }
  }

  return $self->done();
}

1;
