package Genesis::Hook::New::Vault;

use v5.20;
use warnings;

# Only needed for development
BEGIN {push @INC, $ENV{GENESIS_LIB} ? $ENV{GENESIS_LIB} : $ENV{HOME}.'/.genesis/lib'}

use parent qw(Genesis::Hook);

use Genesis qw/bail/;
use Genesis::UI qw/prompt_for_boolean/;

# init - Initialize the hook {{{
sub init {
  my ($class, %ops) = @_;
  my $obj = $class->SUPER::init(%ops);
  $obj->check_minimum_genesis_version('3.1.0');
  return $obj;
}
# }}}

# perform - Main hook execution {{{
sub perform {
  my ($self) = @_;

  # Ask if this is the Genesis Vault (for storing deployment credentials)
  my $genesis_vault = prompt_for_boolean(
    'Is this your Genesis Vault (for storing deployment credentials)?'
  );

  # Build the environment file content
  my $file_content = "---\n";
  $file_content .= "kit:\n";
  $file_content .= "  name:    $ENV{GENESIS_KIT_NAME}\n";
  $file_content .= "  version: $ENV{GENESIS_KIT_VERSION}\n";
  $file_content .= "\n";
  $file_content .= $self->env->genesis_config_block;

  # Add auxiliary_vault param if not a genesis vault
  if (!$genesis_vault) {
    $file_content .= "params:\n";
    $file_content .= "  auxiliary_vault: true\n";
  } else {
    $file_content .= "params: {}\n";
  }

  # Write the environment file
  $self->env->write_manifest($file_content);

  return $self->done();
}
# }}}

1;
# vim: set ts=2 sw=2 sts=2 noet fdm=marker foldlevel=1:
