package JSON::Validator;

=head1 NAME

JSON::Validator - Validate data against a JSON schema

=head1 VERSION

0.51

=head1 SYNOPSIS

  use JSON::Validator;
  my $validator = JSON::Validator->new;

  # Define a schema - http://json-schema.org/examples.html
  # You can also load schema from disk or web
  $validator->schema(
    {
      type       => "object",
      required   => ["firstName", "lastName"],
      properties => {
        firstName => {type => "string"},
        lastName  => {type => "string"},
        age       => {type => "integer", minimum => 0, description => "Age in years"}
      }
    }
  );

  # Validate your data
  @errors = $validator->validate({firstName => "Jan Henning", lastName => "Thorsen", age => -42});

  # Do something if any errors was found
  die "@errors" if @errors;

=head1 DESCRIPTION

L<JSON::Validator> is a class for validating data against JSON schemas.
You might want to use this instead of L<JSON::Schema> if you need to
validate data against L<draft 4|https://github.com/json-schema/json-schema/tree/master/draft-04>
of the specification.

This module is currently EXPERIMENTAL. Hopefully nothing drastic will change,
but it need to fit together nicely with L<Swagger2> - Since this is a spin-off
project.

=head2 Supported schema formats

L<JSON::Validator> can load JSON schemas in multiple formats: Plain perl data
structured (as shown in L</SYNOPSIS>) or files on disk/web in the JSON/YAML
format. The JSON parsing is done using L<Mojo::JSON>, while the YAML parsing
is done with an optional modules which need to be installed manually.
L<JSON::Validator> will look for the YAML modules in this order: L<YAML::XS>,
L<YAML::Syck>, L<YAML::Tiny>, L<YAML>. The order is set by which module that
performs the best, so it might change in the future.

=head2 Resources

Here are some resources that is related to JSON schemas and validation:

=over 4

=item * L<http://json-schema.org/documentation.html>

=item * L<http://spacetelescope.github.io/understanding-json-schema/index.html>

=item * L<http://jsonary.com/documentation/json-schema/>

=item * L<https://github.com/json-schema/json-schema/>

=item * L<Swagger2>

=back

=cut

use Mojo::Base -base;
use Mojo::JSON;
use Mojo::JSON::Pointer;
use Mojo::URL;
use Mojo::Util;
use B;
use File::Basename ();
use File::Spec;
use Scalar::Util;

use constant VALIDATE_HOSTNAME => eval 'require Data::Validate::Domain;1';
use constant VALIDATE_IP       => eval 'require Data::Validate::IP;1';
use constant IV_SIZE           => eval 'require Config;$Config::Config{ivsize}';

use constant DEBUG => $ENV{JSON_VALIDATOR_DEBUG} || $ENV{SWAGGER2_DEBUG} || 0;
use constant WARN_ON_MISSING_FORMAT => $ENV{JSON_VALIDATOR_WARN_ON_MISSING_FORMAT}
  || $ENV{SWAGGER2_WARN_ON_MISSING_FORMAT} ? 1 : 0;

our $VERSION = '0.51';

sub E { bless {path => $_[0] || '/', message => $_[1]}, 'JSON::Validator::Error'; }
sub S { Mojo::Util::md5_sum(Data::Dumper->new([@_])->Sortkeys(1)->Useqq(1)->Dump); }

=head1 ATTRIBUTES

=head2 cache_dir

  $self = $self->cache_dir($path);
  $path = $self->cache_dir;

Path to where downloaded spec files should be cached. Defaults to
C<JSON_VALIDATOR_CACHE_DIR> or the bundled spec files that is shipped
with this distribution.

=head2 coerce

  $self = $self->coerce(1);
  $bool = $self->coerce;

Set this to true if you want to coerce numbers into string and the other way around.

This is EXPERIMENTAL and could be removed without notice!

=head2 formats

  $hash_ref = $self->formats;
  $self = $self->formats(\%hash);

Holds a hash-ref, where the keys are supported JSON type "formats", and
the values holds a code block which can validate a given format.

Note! The modules mentioned below are optional.

=over 4

=item * byte

A padded, base64-encoded string of bytes, encoded with a URL and filename safe
alphabet. Defined by RFC4648.

=item * date

An RFC3339 date in the format YYYY-MM-DD

=item * date-time

An RFC3339 timestamp in UTC time. This is formatted as
"YYYY-MM-DDThh:mm:ss.fffZ". The milliseconds portion (".fff") is optional

=item * double

Cannot test double values with higher precision then what
the "number" type already provides.

=item * email

Validated against the RFC5322 spec.

=item * float

Will always be true if the input is a number, meaning there is no difference
between  L</float> and L</double>. Patches are welcome.

=item * hostname

Will be validated using L<Data::Validate::Domain> if installed.

=item * int32

A signed 32 bit integer.

=item * int64

A signed 64 bit integer. Note: This check is only available if Perl is
compiled to use 64 bit integers.

=item * ipv4

Will be validated using L<Data::Validate::IP> if installed or
fall back to a plain IPv4 IP regex.

=item * ipv6

Will be validated using L<Data::Validate::IP> if installed.

=item * uri

Validated against the RFC3986 spec.

=back

=head2 ua

  $ua = $self->ua;
  $self = $self->ua(Mojo::UserAgent->new);

Holds a L<Mojo::UserAgent> object, used by L</schema> to load a JSON schema
from remote location.

Note that the default L<Mojo::UserAgent> will detect proxy settings and have
L<Mojo::UserAgent/max_redirects> set to 3. (These settings are EXPERIMENTAL
and might change without a warning)

=cut

has cache_dir => sub {
  $ENV{JSON_VALIDATOR_CACHE_DIR} || File::Spec->catdir(File::Basename::dirname(__FILE__), qw( JSON Validator ));
};

has coerce => $ENV{JSON_VALIDATOR_COERCE_VALUES} || $ENV{SWAGGER_COERCE_VALUES} || 0;    # EXPERIMENTAL!

has formats => sub {
  +{
    'byte'      => \&_is_byte_string,
    'date'      => \&_is_date,
    'date-time' => \&_is_date_time,
    'double'    => sub {1},
    'float'     => sub {1},
    'email'     => \&_is_email,
    'hostname'  => VALIDATE_HOSTNAME ? \&Data::Validate::Domain::is_domain : \&_is_domain,
    'int32'     => sub { _is_number($_[0], 'l'); },
    'int64'     => IV_SIZE >= 8 ? sub { _is_number($_[0], 'q'); } : sub {1},
    'ipv4' => VALIDATE_IP ? \&Data::Validate::IP::is_ipv4 : \&_is_ipv4,
    'ipv6' => VALIDATE_IP ? \&Data::Validate::IP::is_ipv6 : \&_is_ipv6,
    'uri'  => \&_is_uri,
  };
};

has ua => sub {
  require Mojo::UserAgent;
  my $ua = Mojo::UserAgent->new;
  $ua->proxy->detect;
  $ua->max_redirects(3);
  $ua;
};

=head1 METHODS

=head2 schema

  $self = $self->schema(\%schema);
  $self = $self->schema($url);
  $schema = $self->schema;

Used to set a schema from either an data structure or from a URL.

C<$schema> will be a L<Mojo::JSON::Pointer> object when loaded,
and C<undef> by default.

The C<$url> can take many forms, but need to point to a text file in the
JSON or YAML format.

=over 4

=item * http://... or https://...

A web resource will be fetched using the L<Mojo::UserAgent>, stored in L</ua>.

=item * data://Some::Module/file.name

This version will use L<Mojo::Loader/data_section> to load "file.name" from
the module "Some::Module".

=item * /path/to/file

An URL (without a recognized scheme) will be loaded from disk.

=back

=cut

sub schema {
  my ($self, $schema) = @_;

  if (@_ == 1) {
    return $self->{schema};
  }
  elsif (ref $schema eq 'HASH') {
    $self->_register_document($schema, $schema->{id} ||= 'http://generated.json.validator.url#');
  }
  else {
    $schema = $self->_load_schema($schema)->data;
  }

  $self->{schema} = Mojo::JSON::Pointer->new($self->_resolve_schema($schema, $schema->{id}, {}));
  $self;
}

=head2 validate

  @errors = $self->validate($data);

Validates C<$data> against a given JSON L</schema>. C<@errors> will
contain objects with containing the validation errors. It will be
empty on success.

Example error element:

  bless {
    message => "Some description",
    path => "/json/path/to/node",
  }, "JSON::Validator::Error"

The error objects are always true in boolean context and will stringify. The
stringification format is subject to change.

=cut

sub validate {
  my ($self, $data, $schema) = @_;
  $schema ||= $self->schema->data;    # back compat with Swagger2::SchemaValidator
  return E '/', 'No validation rules defined.' unless $schema and %$schema;
  return $self->_validate($data, '', $schema);
}

sub _coerce_by_collection_format {
  my ($self, $schema, $data) = @_;
  my $format = $schema->{collectionFormat};
  my @data = $format eq 'ssv' ? split / /, $data : $format eq 'tsv' ? split /\t/,
    $data : $format eq 'pipes' ? split /\|/, $data : split /,/, $data;

  return [map { $_ + 0 } @data] if $schema->{type} and $schema->{type} =~ m!^(integer|number)$!;
  return \@data;
}

sub _load_schema {
  my ($self, $url) = @_;
  my ($namespace, $scheme) = ("$url", "file");
  my $doc;

  if ($namespace =~ m!^https?://!) {
    $url = Mojo::URL->new($url);
    ($namespace, $scheme) = ($url->clone->fragment(undef)->port(undef)->to_string, $url->scheme);
  }
  elsif ($namespace =~ m!^data://(.*)!) {
    $scheme = 'data';
  }

  # Make sure we create the correct namespace if not already done by Mojo::URL
  $namespace =~ s!#.*$!! if $namespace eq $url;

  return $self->{cached}{$namespace} if $self->{cached}{$namespace};
  return eval {
    warn "[JSON::Validator] Loading schema from $url ($namespace)\n" if DEBUG;
    $doc
      = $scheme eq 'file' ? Mojo::Util::slurp($namespace)
      : $scheme eq 'data' ? $self->_load_schema_from_data($url, $namespace)
      :                     $self->_load_schema_from_url($url, $namespace);
    $self->_register_document($self->_load_schema_from_text($doc), $namespace);
  } || do {
    die "Could not load document from $url: $@ ($doc)" if DEBUG;
    die "Could not load document from $url: $@";
  };
}

sub _load_schema_from_data {
  my ($self, $url, $namespace) = @_;
  require Mojo::Loader;
  $namespace =~ m!^data://([^/]+)/(.*)$!;
  Mojo::Loader::data_section($1 || 'main', $2 || $namespace);
}

sub _load_schema_from_text {
  $_[1] =~ /^\s*\{/s ? Mojo::JSON::decode_json($_[1]) : _load_yaml($_[1]);
}

sub _load_schema_from_url {
  my ($self, $url, $namespace) = @_;
  my $cache_file = File::Spec->catfile($self->cache_dir, Mojo::Util::md5_sum($namespace));

  return Mojo::Util::slurp($cache_file) if -r $cache_file;
  my $doc = $self->ua->get($url)->res->body;
  Mojo::Util::spurt($doc, $cache_file) if $self->cache_dir and -w $self->cache_dir;
  return $doc;
}

sub _register_document {
  my ($self, $doc, $namespace) = @_;

  $doc = Mojo::JSON::Pointer->new($doc);
  $namespace = Mojo::URL->new($namespace) unless ref $namespace;
  $namespace->fragment(undef)->port(undef);

  warn "[JSON::Validator] Register $namespace\n" if DEBUG;

  $self->{cached}{$namespace} = $doc;
  $doc->data->{id} ||= "$namespace";
  $self->{cached}{$doc->data->{id}} = $doc;
  $doc;
}

sub _resolve_ref {
  my ($self, $ref, $namespace, $refs) = @_;

  return if !$ref or ref $ref;
  $ref = "#/definitions/$ref" if $ref =~ /^\w+$/;
  $ref = Mojo::URL->new($namespace)->fragment($ref) if $ref =~ s!^\#!!;
  $ref = Mojo::URL->new($ref) unless UNIVERSAL::isa($ref, 'Mojo::URL');

  return $refs->{$ref} if $refs->{$ref};

  warn "[JSON::Validator] Resolve $ref\n" if DEBUG;
  $refs->{$ref} = {};
  my $doc = $self->_load_schema($ref);
  my $def = $self->_resolve_schema($doc->get($ref->fragment), $doc->data->{id}, $refs);
  delete $def->{id};
  $refs->{$ref}{$_} = $def->{$_} for keys %$def;
  $refs->{$ref};
}

sub _resolve_schema {
  my ($self, $obj, $namespace, $refs) = @_;
  my $copy = ref $obj eq 'ARRAY' ? [] : {};
  my $ref;

  if (ref $obj eq 'HASH') {
    $obj = $ref if $ref = $self->_resolve_ref($obj->{'$ref'}, $namespace, $refs);
    $copy->{$_} = $self->_resolve_schema($obj->{$_}, $namespace, $refs) for keys %$obj;
    delete $copy->{'$ref'};
    return $copy;
  }
  elsif (ref $obj eq 'ARRAY') {
    $copy->[$_] = $self->_resolve_schema($obj->[$_], $namespace, $refs) for 0 .. @$obj - 1;
    return $copy;
  }

  return $obj;
}

sub _validate {
  my ($self, $data, $path, $schema) = @_;
  my ($type) = (map { $schema->{$_} } grep { $schema->{$_} } qw( type allOf anyOf oneOf ))[0];
  my $check_all = grep { $schema->{$_} } qw( allOf oneOf );
  my @errors;

  $type = 'object' if !$type and $schema->{properties};
  $type ||= 'any';

  #$SIG{__WARN__} = sub { Carp::confess(Data::Dumper::Dumper($schema)) };

  if ($schema->{not}) {
    @errors = $self->_validate($data, $path, $schema->{not});
    return @errors ? () : (E $path, "Should not match.");
  }

  for my $t (ref $type eq 'ARRAY' ? @$type : ($type)) {
    $t //= 'null';
    if (ref $t eq 'HASH') {
      push @errors, [$self->_validate($data, $path, $t)];
      return if !$check_all and !@{$errors[-1]};    # valid
    }
    elsif (my $code = $self->can(sprintf '_validate_type_%s', $t)) {
      push @errors, [$self->$code($data, $path, $schema)];
      return if !$check_all and !@{$errors[-1]};    # valid
    }
    elsif ($t eq 'file') {
      return;                                       # Skip validating raw file
    }
    else {
      return E $path, "Cannot validate type '$t'";
    }
  }

  if ($schema->{oneOf}) {
    my $n = grep { @$_ == 0 } @errors;
    return if $n == 1;                              # one match
    return E $path, "Expected only one to match." if $n == @errors;
  }

  if (@errors > 1) {
    my %err;
    for my $i (0 .. @errors - 1) {
      for my $e (@{$errors[$i]}) {
        if ($e->{message} =~ m!Expected ([^\.]+)\ - got ([^\.]+)\.!) {
          push @{$err{$e->{path}}}, [$i, $e->{message}, $1, $2];
        }
        else {
          push @{$err{$e->{path}}}, [$i, $e->{message}];
        }
      }
    }
    unshift @errors, [];
    for my $p (sort keys %err) {
      my %uniq;
      my @e = grep { !$uniq{$_->[1]}++ } @{$err{$p}};
      if (@e == grep { defined $_->[2] } @e) {
        push @{$errors[0]}, E $p, sprintf 'Expected %s - got %s.', join(', ', map { $_->[2] } @e), $e[0][3];
      }
      else {
        push @{$errors[0]}, E $p, join ' ', map {"[$_->[0]] $_->[1]"} @e;
      }
    }
  }

  return @{$errors[0]};
}

sub _validate_additional_properties {
  my ($self, $data, $path, $schema) = @_;
  my $properties = $schema->{additionalProperties};
  my @errors;

  if (ref $properties eq 'HASH') {
    push @errors, $self->_validate_properties($data, $path, $schema);
  }
  elsif (!$properties) {
    my @keys = grep { $_ !~ /^(description|id|title)$/ } keys %$data;
    if (@keys) {
      local $" = ', ';
      push @errors, E $path, "Properties not allowed: @keys.";
    }
  }

  return @errors;
}

sub _validate_enum {
  my ($self, $data, $path, $schema) = @_;
  my $enum = $schema->{enum};
  my $m    = S $data;

  for my $i (@$enum) {
    return if $m eq S $i;
  }

  local $" = ', ';
  return E $path, "Not in enum list: @$enum.";
}

sub _validate_format {
  my ($self, $value, $path, $schema) = @_;
  my $code = $self->formats->{$schema->{format}};

  unless ($code) {
    warn "Format rule for '$schema->{format}' is missing" if WARN_ON_MISSING_FORMAT;
    return;
  }

  return if $code->($value);
  return E $path, "Does not match $schema->{format} format.";
}

sub _validate_pattern_properties {
  my ($self, $data, $path, $schema) = @_;
  my $properties = $schema->{patternProperties};
  my @errors;

  for my $pattern (keys %$properties) {
    my $v = $properties->{$pattern};
    for my $tk (keys %$data) {
      next unless $tk =~ /$pattern/;
      push @errors, $self->_validate(delete $data->{$tk}, _path($path, $tk), $v);
    }
  }

  return @errors;
}

sub _validate_properties {
  my ($self, $data, $path, $schema) = @_;
  my $properties = $schema->{properties};
  my $required   = $schema->{required};
  my (@errors, %required);

  if ($required and ref $required eq 'ARRAY') {
    $required{$_} = 1 for @$required;
  }

  for my $name (keys %$properties) {
    my $p = $properties->{$name};
    if (exists $data->{$name}) {
      my $v = delete $data->{$name};
      push @errors, $self->_validate_enum($v, $path, $p) if $p->{enum};
      push @errors, $self->_validate($v, _path($path, $name), $p);
    }
    elsif ($p->{default}) {
      $data->{$name} = $p->{default};
    }
    elsif ($required{$name}) {
      push @errors, E _path($path, $name), "Missing property.";
    }
    elsif (_is_true($p->{required}) eq '1') {
      push @errors, E _path($path, $name), "Missing property.";
    }
  }

  return @errors;
}

sub _validate_type_any {
  return;
}

sub _validate_type_array {
  my ($self, $data, $path, $schema) = @_;
  my @errors;

  if (ref $schema->{items} eq 'HASH' and $schema->{items}{collectionFormat}) {
    $data = $self->_coerce_by_collection_format($schema->{items}, $data);
  }
  if (ref $data ne 'ARRAY') {
    return E $path, _expected(array => $data);
  }

  $data = [@$data];

  if (defined $schema->{minItems} and $schema->{minItems} > @$data) {
    push @errors, E $path, sprintf 'Not enough items: %s/%s.', int @$data, $schema->{minItems};
  }
  if (defined $schema->{maxItems} and $schema->{maxItems} < @$data) {
    push @errors, E $path, sprintf 'Too many items: %s/%s.', int @$data, $schema->{maxItems};
  }
  if ($schema->{uniqueItems}) {
    my %uniq;
    for (@$data) {
      next if !$uniq{S($_)}++;
      push @errors, E $path, 'Unique items required.';
      last;
    }
  }
  if (ref $schema->{items} eq 'ARRAY') {
    my $additional_items = $schema->{additionalItems} // 1;
    my @v = @{$schema->{items}};

    if ($additional_items) {
      push @v, $a while @v < @$data;
    }

    if (@v == @$data) {
      for my $i (0 .. @v - 1) {
        push @errors, $self->_validate($data->[$i], "$path/$i", $v[$i]);
      }
    }
    elsif (!$additional_items) {
      push @errors, E $path, sprintf "Invalid number of items: %s/%s.", int(@$data), int(@v);
    }
  }
  elsif (ref $schema->{items} eq 'HASH') {
    for my $i (0 .. @$data - 1) {
      if ($schema->{items}{properties}) {
        my $input = ref $data->[$i] eq 'HASH' ? {%{$data->[$i]}} : $data->[$i];
        push @errors, $self->_validate_properties($input, "$path/$i", $schema->{items});
      }
      else {
        push @errors, $self->_validate($data->[$i], "$path/$i", $schema->{items});
      }
    }
  }

  return @errors;
}

sub _validate_type_boolean {
  my ($self, $value, $path, $schema) = @_;

  return if defined $value and ("$value" eq "1" or "$value" eq "0");
  return E $path, _expected(boolean => $value);
}

sub _validate_type_integer {
  my ($self, $value, $path, $schema) = @_;
  my @errors = $self->_validate_type_number($value, $path, $schema, 'integer');

  return @errors if @errors;
  return if $value =~ /^-?\d+$/;
  return E $path, "Expected integer - got number.";
}

sub _validate_type_null {
  my ($self, $value, $path, $schema) = @_;

  return E $path, 'Not null.' if defined $value;
  return;
}

sub _validate_type_number {
  my ($self, $value, $path, $schema, $expected) = @_;
  my @errors;

  $expected ||= 'number';

  if (!defined $value or ref $value) {
    return E $path, _expected($expected => $value);
  }
  unless (B::svref_2object(\$value)->FLAGS & (B::SVp_IOK | B::SVp_NOK) and 0 + $value eq $value and $value * 0 == 0) {
    return E $path, "Expected $expected - got string." if !$self->coerce or $value =~ /\D/;
    $_[1] = 0 + $value;    # coerce input value
  }

  if ($schema->{format}) {
    push @errors, $self->_validate_format($value, $path, $schema);
  }
  if (my $e = _cmp($schema->{minimum}, $value, $schema->{exclusiveMinimum}, '<')) {
    push @errors, E $path, "$value $e minimum($schema->{minimum})";
  }
  if (my $e = _cmp($value, $schema->{maximum}, $schema->{exclusiveMaximum}, '>')) {
    push @errors, E $path, "$value $e maximum($schema->{maximum})";
  }
  if (my $d = $schema->{multipleOf}) {
    unless (int($value / $d) == $value / $d) {
      push @errors, E $path, "Not multiple of $d.";
    }
  }

  return @errors;
}

sub _validate_type_object {
  my ($self, $data, $path, $schema) = @_;
  my @errors;

  if (ref $data ne 'HASH') {
    return E $path, _expected(object => $data);
  }

  # make sure _validate_xxx() does not mess up original $data
  $data = {%$data};

  if (defined $schema->{maxProperties} and $schema->{maxProperties} < keys %$data) {
    push @errors, E $path, sprintf 'Too many properties: %s/%s.', int(keys %$data), $schema->{maxProperties};
  }
  if (defined $schema->{minProperties} and $schema->{minProperties} > keys %$data) {
    push @errors, E $path, sprintf 'Not enough properties: %s/%s.', int(keys %$data), $schema->{minProperties};
  }
  if ($schema->{properties}) {
    push @errors, $self->_validate_properties($data, $path, $schema);
  }
  if ($schema->{patternProperties}) {
    push @errors, $self->_validate_pattern_properties($data, $path, $schema);
  }
  if (exists $schema->{additionalProperties}) {
    push @errors, $self->_validate_additional_properties($data, $path, $schema);
  }

  return @errors;
}

sub _validate_type_string {
  my ($self, $value, $path, $schema) = @_;
  my @errors;

  if (!defined $value or ref $value) {
    return E $path, _expected(string => $value);
  }
  if (B::svref_2object(\$value)->FLAGS & (B::SVp_IOK | B::SVp_NOK) and 0 + $value eq $value and $value * 0 == 0) {
    return E $path, "Expected string - got number." unless $self->coerce;
    $_[1] = "$value";    # coerce input value
  }
  if ($schema->{format}) {
    push @errors, $self->_validate_format($value, $path, $schema);
  }
  if (defined $schema->{maxLength}) {
    if (length($value) > $schema->{maxLength}) {
      push @errors, E $path, sprintf "String is too long: %s/%s.", length($value), $schema->{maxLength};
    }
  }
  if (defined $schema->{minLength}) {
    if (length($value) < $schema->{minLength}) {
      push @errors, E $path, sprintf "String is too short: %s/%s.", length($value), $schema->{minLength};
    }
  }
  if (defined $schema->{pattern}) {
    my $p = $schema->{pattern};
    unless ($value =~ /$p/) {
      push @errors, E $path, "String does not match '$p'";
    }
  }

  return @errors;
}

# FUNCTIONS ==================================================================

sub _cmp {
  return undef if !defined $_[0] or !defined $_[1];
  return "$_[3]=" if $_[2] and $_[0] >= $_[1];
  return $_[3] if $_[0] > $_[1];
  return "";
}

sub _expected {
  my $type = _guess($_[1]);
  return "Expected $_[0] - got different $type." if $_[0] =~ /\b$type\b/;
  return "Expected $_[0] - got $type.";
}

sub _guess {
  local $_ = $_[0];
  my $ref     = ref;
  my $blessed = Scalar::Util::blessed($_[0]);
  return 'object' if $ref eq 'HASH';
  return lc $ref if $ref and !$blessed;
  return 'null' if !defined;
  return 'boolean' if $blessed and "$_" eq "1" or "$_" eq "0";
  return 'integer' if /^\d+$/;
  return 'number' if B::svref_2object(\$_)->FLAGS & (B::SVp_IOK | B::SVp_NOK) and 0 + $_ eq $_ and $_ * 0 == 0;
  return $blessed || 'string';
}

sub _is_byte_string { $_[0] =~ /^[A-Za-z0-9\+\/\=]+$/; }
sub _is_date        { $_[0] =~ qr/^(\d+)-(\d+)-(\d+)$/io; }
sub _is_date_time   { $_[0] =~ qr/^(\d+)-(\d+)-(\d+)T(\d+):(\d+):(\d+(?:\.\d+)?)(?:Z|([+-])(\d+):(\d+))?$/io; }
sub _is_domain      { warn "Data::Validate::Domain is not installed"; return; }

sub _is_email {
  state $email_rfc5322_re = do {
    my $atom           = qr;[a-zA-Z0-9_!#\$\%&'*+/=?\^`{}~|\-]+;o;
    my $quoted_string  = qr/"(?:\\[^\r\n]|[^\\"])*"/o;
    my $domain_literal = qr/\[(?:\\[\x01-\x09\x0B-\x0c\x0e-\x7f]|[\x21-\x5a\x5e-\x7e])*\]/o;
    my $dot_atom       = qr/$atom(?:[.]$atom)*/o;
    my $local_part     = qr/(?:$dot_atom|$quoted_string)/o;
    my $domain         = qr/(?:$dot_atom|$domain_literal)/o;

    qr/$local_part\@$domain/o;
  };

  return $_[0] =~ $email_rfc5322_re;
}

sub _is_ipv4 {
  my (@octets) = $_[0] =~ /^(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})$/;
  return 4 == grep { $_ >= 0 && $_ <= 255 && $_ !~ /^0\d{1,2}$/ } @octets;
}

sub _is_ipv6 { warn "Data::Validate::IP is not installed"; return; }

sub _is_number {
  return unless $_[0] =~ /^-?\d+(\.\d+)?$/;
  return $_[0] eq unpack $_[1], pack $_[1], $_[0];
}

sub _is_true {
  return $_[0] if ref $_[0] and !Scalar::Util::blessed($_[0]);
  return 0 if !$_[0] or $_[0] =~ /^(n|false|off)/i;
  return 1;
}

sub _is_uri { $_[0] =~ qr!^(([^:/?#]+):)?(//([^/?#]*))?([^?#]*)(\?([^#]*))?(#(.*))?!o; }

# Please report if you need to manually monkey patch this function
# https://github.com/jhthorsen/json-validator/issues
sub _load_yaml {
  my @YAML_MODULES = qw( YAML::XS YAML::Syck YAML::Tiny YAML );        # subject to change
  my $YAML_MODULE = (grep { eval "require $_;1" } @YAML_MODULES)[0];
  die "Need to install a YAML module: @YAML_MODULES" unless $YAML_MODULE;
  Mojo::Util::monkey_patch(__PACKAGE__, _load_yaml => eval "\\\&$YAML_MODULE\::Load");
  _load_yaml(@_);
}

sub _path {
  local $_ = $_[1];
  s!~!~0!g;
  s!/!~1!g;
  "$_[0]/$_";
}

package    # hide from
  JSON::Validator::Error;

use overload q("") => sub { sprintf '%s: %s', @{$_[0]}{qw( path message )} }, bool => sub {1}, fallback => 1;
sub message { shift->{message} }
sub path    { shift->{path} }
sub TO_JSON { {message => $_[0]->{message}, path => $_[0]->{path}} }

=head1 COPYRIGHT AND LICENSE

Copyright (C) 2014-2015, Jan Henning Thorsen

This program is free software, you can redistribute it and/or modify it under
the terms of the Artistic License version 2.0.

=head1 AUTHOR

Jan Henning Thorsen - C<jhthorsen@cpan.org>

=cut

1;
