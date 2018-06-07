use v6;
use Test;
plan 18;

use PDF::IO;

my $ioh = "t/helloworld.pdf".IO;

my $in-ioh = PDF::IO.coerce( $ioh );
my Str $str = $ioh.slurp( :enc<latin-1> );
my $in-str = PDF::IO.coerce( $str );

for :$in-ioh, :$in-str {
    my ($test, $input) = .kv;
    is $input.codes, $str.codes, "$test .codes";
    is $input.read(4).decode("latin-1"), "%PDF", "$test read";
    lives-ok {$input.seek(1, SeekFromCurrent);}, "$test seek";
    is $input.read(3).decode("latin-1"), "1.3", "$test read";
    is $input.byte-str(1, 5), 'PDF-1', "$test head byte-str";
    nok $input.eof, "$test not at eof yet";
    $input.read(9999);
    ok $input.eof, "$test now at eof";
    is $input.byte-str(*-4), '%EOF', "$test tail byte-str";
    lives-ok { $input.close }, "$test close";
}

done-testing;
