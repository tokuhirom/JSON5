use strict;
use warnings;
use utf8;
use Test::More;
use JSON5 qw(decode_json5);
use JSON::PP qw(decode_json);
use File::Find;

# Because, JSON.parse('"This /* block comment */ isn\'t really a block comment."') passed on node.
my $JSON = JSON::PP->new->allow_nonref(1);
my @files = files();
for my $file (grep !/\.pl\z/, @files) {
    subtest $file, sub {
        my $json5 = slurp($file);
        my $ext = get_ext($file);
        note $json5;
        my $got = eval { decode_json5($json5) };
        if ($ext eq 'json') {
            ok !$@;
            is_deeply($got, $JSON->decode($json5));
        } elsif ($ext eq 'json5') {
            diag $@;
            ok !$@;
            ok 1; # TODO
            my $pl_file = pl_file($file);
            if (-f $pl_file) {
                my $pl = do $pl_file or die $@;
                is_deeply($got, $pl);
            } else {
                die "Missing $pl_file" if $ENV{RELEASE_TEST};
                warn "Missing $pl_file";
            }
        } elsif ($ext eq 'js') {
            diag $@;
            ok $@; # invalid json
        } elsif ($ext eq 'txt') {
            diag $@;
            ok $@; # invalid json
        } else {
            die "Unknown extension: $ext";
        }
    };
}

done_testing;

sub pl_file {
    my $filename = shift;
    $filename =~ s/\.[^.]+?\z/\.pl/;
    $filename;
}

sub get_ext {
    my $filename = shift;
    $filename =~ /\.([^.]+?)\z/ or die "Can't get extension: $filename";
    return $1;
}

sub slurp {
    my $fname = shift;
    open my $fh, '<', $fname
        or Carp::croak("Can't open '$fname' for reading: '$!'");
    scalar(do { local $/; <$fh> })
}

sub files {
    my @files;
    find(+{
        wanted => sub {
            push @files, $_ if -f $_
        },
        no_chdir => 1,
    }, 't/parse-cases');
    return sort @files;
}
