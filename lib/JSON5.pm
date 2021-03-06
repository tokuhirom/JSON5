package JSON5;
use 5.008001;
use strict;
use warnings;

our $VERSION = "0.01";

# JSON5 implementation adapted from JSON::Tiny.
# JSON::Tiny was adapted from Mojo::JSON.
#
# JSON5.pm's license is:
#   (c)2014 Tokuhiro Matsuno
#   License: Artistic 2.0 license.
#   http://www.perlfoundation.org/artistic_license_2_0.
#
# JSON::Tiny's license is:
#   (c)2012-2014 David Oswald
#   License: Artistic 2.0 license.
#   http://www.perlfoundation.org/artistic_license_2_0.

use strict;
use warnings;
use B;
use Carp 'croak';
use Exporter 'import';
use Scalar::Util 'blessed';
use Encode ();

our @EXPORT_OK = qw(decode_json5 encode_json5 j5);

# Constructor and error inlined from Mojo::Base
sub new {
  my $class = shift;
  bless @_ ? @_ > 1 ? {@_} : {%{$_[0]}} : {}, ref $class || $class;
}

sub error {
  return $_[0]{error} if @_ == 1;
  $_[0]{error} = $_[1];
  $_[0];
}

# Literal names
# Users may override Booleans with literal 0 or 1 if desired.
our $FALSE = bless \(my $false = 0), 'JSON::Tiny::_Bool';
our $TRUE  = bless \(my $true  = 1), 'JSON::Tiny::_Bool';
our $INFINITY = 0+"inf";

# Escaped special character map with u2028 and u2029
my %ESCAPE = (
  '"'     => '"',
  '\\'    => '\\',
  '/'     => '/',
  'b'     => "\x08",
  'f'     => "\x0c",
  'n'     => "\x0a",
  'r'     => "\x0d",
  't'     => "\x09",
  'u2028' => "\x{2028}",
  'u2029' => "\x{2029}"
);
my %REVERSE = map { $ESCAPE{$_} => "\\$_" } keys %ESCAPE;

for(0x00 .. 0x1f) {
  my $packed = pack 'C', $_;
  $REVERSE{$packed} = sprintf '\u%.4X', $_
    if ! defined $REVERSE{$packed};
}

my $WHITESPACE_RE = qr/[\x20\x09\x0a\x0d]*/;

sub decode {
  my $self = shift->error(undef);
  my $value;
  return $value if eval{ $value = _decode(shift); 1 };
  $self->error(_chomp($@));
  return undef;  ## no critic(return)
}

sub decode_json5 {
  my $value;
  return eval { $value = _decode(shift); 1 } ? $value : croak _chomp($@);
}

sub encode { encode_json5($_[1]) }

sub encode_json5 { Encode::encode 'UTF-8', _encode_value(shift); }

sub false {$FALSE}

sub j5 {
  return encode_json5 $_[0] if ref $_[0] eq 'ARRAY' || ref $_[0] eq 'HASH';
  return decode_json5 $_[0];
}

sub true {$TRUE}

sub _chomp { chomp $_[0] ? $_[0] : $_[0] }

sub _decode {
  # Missing input
  die "Missing or empty input\n" unless length(local $_ = shift);

  # Wide characters
  die "Wide character in input\n" unless utf8::downgrade($_, 1);

  # UTF-8
  die "Input is not UTF-8 encoded\n"
    unless eval { $_ = Encode::decode('UTF-8', $_, 1); 1 };

  # Value
  my $value = _decode_value();

  _decode_comment();
  
  # Leftover data
  _exception('Unexpected data') unless m/\G$WHITESPACE_RE\z/gc;

  return $value;
}

sub _decode_array {
  my @array;
  until (m/\G$WHITESPACE_RE\]/gc) {

    # Value
    push @array, _decode_value();

    # JSON5: Allow trailing comma
    last if m/\G(?:$WHITESPACE_RE,)?$WHITESPACE_RE\]/gc;

    # Separator
    redo if m/\G$WHITESPACE_RE,/gc;

    # End
    last if m/\G(?:$WHITESPACE_RE,)?$WHITESPACE_RE\]/gc;

    # Invalid character
    _exception('Expected comma or right square bracket while parsing array');
  }

  return \@array;
}

sub _decode_object {
  my %hash;
  until (m/\G$WHITESPACE_RE\}/gc) {

    # Quote
    m/\G$WHITESPACE_RE"/gc
      or _exception('Expected string while parsing object');

    # Key
    my $key = _decode_string();

    # Colon
    m/\G$WHITESPACE_RE:/gc
      or _exception('Expected colon while parsing object');

    # Value
    $hash{$key} = _decode_value();

    # Separator
    redo if m/\G$WHITESPACE_RE,/gc;

    # End
    last if m/\G$WHITESPACE_RE\}/gc;

    # Invalid character
    _exception('Expected comma or right curly bracket while parsing object');
  }

  return \%hash;
}

sub _decode_string {
  my $pos = pos;
  
  # Extract string with escaped characters
  m!\G((?:(?:[^\x00-\x1f\\"]|\\(?:["\\/bfnrt]|u[0-9a-fA-F]{4})){0,32766})*)!gc; # segfault on 5.8.x in t/20-mojo-json.t
  my $str = $1;

  # Invalid character
  unless (m/\G"/gc) {
    _exception('Unexpected character or invalid escape while parsing string')
      if m/\G[\x00-\x1f\\]/;
    _exception('Unterminated string');
  }

  # Unescape popular characters
  if (index($str, '\\u') < 0) {
    $str =~ s!\\(["\\/bfnrt])!$ESCAPE{$1}!gs;
    return $str;
  }

  # Unescape everything else
  my $buffer = '';
  while ($str =~ m/\G([^\\]*)\\(?:([^u])|u(.{4}))/gc) {
    $buffer .= $1;

    # Popular character
    if ($2) { $buffer .= $ESCAPE{$2} }

    # Escaped
    else {
      my $ord = hex $3;

      # Surrogate pair
      if (($ord & 0xf800) == 0xd800) {

        # High surrogate
        ($ord & 0xfc00) == 0xd800
          or pos($_) = $pos + pos($str), _exception('Missing high-surrogate');

        # Low surrogate
        $str =~ m/\G\\u([Dd][C-Fc-f]..)/gc
          or pos($_) = $pos + pos($str), _exception('Missing low-surrogate');

        $ord = 0x10000 + ($ord - 0xd800) * 0x400 + (hex($1) - 0xdc00);
      }

      # Character
      $buffer .= pack 'U', $ord;
    }
  }

  # The rest
  return $buffer . substr $str, pos $str, length $str;
}

sub _decode_comment {
  # JSON5: comments
  m!\G/\*.*?\*/!gcs;
}

sub _decode_value {

  # Leading whitespace
  m/\G$WHITESPACE_RE/gc;

  # String
  return _decode_string() if m/\G"/gc;

  # Object
  return _decode_object() if m/\G\{/gc;

  # Array
  return _decode_array() if m/\G\[/gc;

  # Number
  return 0 + $1
    if m/\G([-]?(?:0|[1-9][0-9]*)(?:\.[0-9]*)?(?:[eE][+-]?[0-9]+)?)/gc;

  # True
  return $TRUE if m/\Gtrue/gc;

  # Infinity
  return $INFINITY if m/\GInfinity/gc;

  # False
  return $FALSE if m/\Gfalse/gc;

  # Null
  return undef if m/\Gnull/gc;  ## no critic (return)

  # Invalid character
  _exception('Expected string, array, object, number, boolean or null');
}

sub _encode_array {
  my $array = shift;
  '[' . join(',', map { _encode_value($_) } @$array) . ']';
}

sub _encode_object {
  my $object = shift;
  my @pairs = map { _encode_string($_) . ':' . _encode_value($object->{$_}) }
    keys %$object;
  return '{' . join(',', @pairs) . '}';
}

sub _encode_string {
  my $str = shift;
  $str =~ s!([\x00-\x1f\x{2028}\x{2029}\\"/])!$REVERSE{$1}!gs;
  return "\"$str\"";
}

sub _encode_value {
  my $value = shift;

  # Reference
  if (my $ref = ref $value) {

    # Object
    return _encode_object($value) if $ref eq 'HASH';

    # Array
    return _encode_array($value) if $ref eq 'ARRAY';

    # True or false
    return $$value ? 'true' : 'false' if $ref eq 'SCALAR';
    return $value  ? 'true' : 'false' if $ref eq 'JSON::Tiny::_Bool';

    # Blessed reference with TO_JSON method
    if (blessed $value && (my $sub = $value->can('TO_JSON'))) {
      return _encode_value($value->$sub);
    }
  }

  # Null
  return 'null' unless defined $value;

  # Number
  return $value
    if B::svref_2object(\$value)->FLAGS & (B::SVp_IOK | B::SVp_NOK)
    && 0 + $value eq $value
    && $value * 0 == 0;

  # String
  return _encode_string($value);
}

sub _exception {

  # Leading whitespace
  m/\G$WHITESPACE_RE/gc;

  # Context
  my $context = 'Malformed JSON: ' . shift;
  if (m/\G\z/gc) { $context .= ' before end of data' }
  else {
    my @lines = split "\n", substr($_, 0, pos);
    $context .= ' at line ' . @lines . ', offset ' . length(pop @lines || '');
  }

  die "$context\n";
}

# Emulate boolean type
package JSON5::_Bool;
use overload '0+' => sub { ${$_[0]} }, '""' => sub { ${$_[0]} }, fallback => 1;

1;

1;
__END__

=encoding utf-8

=head1 NAME

JSON5 - It's new $module

=head1 SYNOPSIS

    use JSON5;

=head1 DESCRIPTION

JSON5 is ...

=head1 LICENSE

Copyright (C) Tokuhiro Matsuno.

This library is free software; you can redistribute it and/or modify
it under the same terms as Perl itself.

=head1 AUTHOR

Tokuhiro Matsuno E<lt>tokuhirom@gmail.comE<gt>

=cut

