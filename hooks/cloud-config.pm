#!/usr/bin/env perl
# vim: set ts=2 sw=2 sts=2 foldmethod=marker
package Genesis::Hook::CloudConfig::Vault v4.0.0;

use strict;
use warnings;
use v5.20; # Genesis min perl version is 5.20

# Only needed for development
BEGIN {push @INC, $ENV{GENESIS_LIB} ? $ENV{GENESIS_LIB} : $ENV{HOME}.'/.genesis/lib'}

use parent qw(Genesis::Hook::CloudConfig);

use Genesis::Hook::CloudConfig::Helpers qw/gigabytes megabytes/;

use Genesis qw//;
use JSON::PP;

sub init {
	my $class = shift;
	my $obj = $class->SUPER::init(@_);
	$obj->check_minimum_genesis_version('3.1.0-rc.20');
	return $obj;
}

sub stackit_subnet_reference {
	my ($self, $property) = @_;
	# Custom method to handle stackit's 1:1 network:subnet relationship
	# This extracts subnet information directly instead of using network references
	return $self->subnet_reference($property);
}

sub perform {
	my ($self) = @_;
	return 1 if $self->completed;

	my $config = $self->build_cloud_config({
		'networks' => [
			$self->network_definition('vault', strategy => 'ocfp',
				dynamic_subnets => {
					allocation => {
						size => 0,
						statics => 0,
					},
					cloud_properties_for_iaas => {
						aws => {
							'subnet' => $self->subnet_reference('id'),
						},
						openstack => {
							'net_id' => $self->network_reference('id'), # TODO: $self->subnet_reference('net_id'),
							'security_groups' => ['default'] #$self->subnet_reference('sgs', 'get_security_groups'),
						},
						stackit => {
							'net_id' => $self->subnet_reference('parent_network_id'), # Use subnet_reference for 1:1 network:subnet relationship
							'security_groups' => $self->network_reference('sgs', 'get_sgs_by_names', 'ocfp', 'default'),
						},
					},
				}
			)
		],
		'vm_types' => [
			$self->vm_type_definition('vault',
				cloud_properties_for_iaas => {
					aws => {
						'instance_type' => $self->for_scale({
							dev => 't3.medium',
							prod => 'm6i.large'
						}, 't3.medium'),
						'ephemeral_disk' => {
							'encrypted' => $self->TRUE,
							'size' => $self->for_scale({
								dev => 4096,
								prod => 16384
							}, 4096),
							'type' => 'gp3'
						},
						'metadata_options' => {
							'http_tokens' => 'required'
						},
					},
					openstack => {
						'instance_type' => $self->for_scale({
							dev => 'm1.2',
							prod => 'm1.3'
						}, 'm1.2'),
						'boot_from_volume' => $self->TRUE,
						'root_disk' => {
							'size' => 32 # in gigabytes
						},
					},
					stackit => {
						'instance_type' => $self->for_scale({
							dev => 'm1.2',
							prod => 'm1.3'
						}, 'm1.2'),
						'boot_from_volume' => $self->TRUE,
						'root_disk' => {
							'size' => 32 # in gigabytes
						},
					},
				},
			),
		],
		'disk_types' => [
			$self->disk_type_definition('vault',
				common => {
					disk_size => $self->for_scale({ # add $self->for_feature('internal-blobstore')
						dev => gigabytes(64),
						prod => gigabytes(128)
					}, gigabytes(96)),
				},
				cloud_properties_for_iaas => {
					aws => {
						'encrypted' => $self->TRUE,
						'type' => 'gp3',
					},
					openstack => {
						'type' => 'storage_premium_perf6',
					},
					stackit => {
						'type' => 'storage_premium_perf6',
					},
				},
			),
		],
		'vm_extensions' => [
			$self->vm_extension_definition('vault-lb',
				'cloud_properties_for_iaas' => {
					aws => {
						'lb_target_groups' => [$self->env->lookup(
							'cloud-config.vault-lb-target-group',
							'ocfp-' . ( $ENV{GENESIS_ENVIRONMENT} || 'mgmt' ) . '-vault-lb-tg'
						)]
					}					
				}
			)
		],
	});

	$self->done($config);
}

sub get_sgs_by_names {
	my ($self, $subnet_data, $ref, @names) = @_;
	my @ids = map {$subnet_data->{$ref}{$_}{id}} @names;
	# TODO: Error checking
	return \@ids
}
1;
