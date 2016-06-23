use v6;

use PDF::Storage::Crypt;
use PDF::Storage::Crypt::AST;

class PDF::Storage::Crypt::AES
    is PDF::Storage::Crypt
    does PDF::Storage::Crypt::AST {

    use OpenSSL::CryptTools;
    use PDF::Storage::Blob;
    use PDF::Storage::Util :resample;
    
    constant KeyLen = 16;

    submethod BUILD(UInt :$Length = 128, |c) {
        die "unsupported AES encryption key length: $Length"
            unless $Length == 16|128;
    }
    
    method !aes-encrypt($key, $msg, :$iv --> Buf) {
        OpenSSL::CryptTools::encrypt( :aes128, $msg, :$key, :$iv);
    }

    method !aes-decrypt($key, $msg, :$iv --> Buf) {
        OpenSSL::CryptTools::decrypt( :aes128, $msg, :$key, :$iv);
    }

    method type { 'AESV2' }

    method !object-key(UInt $obj-num, UInt $gen-num ) {
	die "encryption has not been authenticated"
	    unless $.key;

	my uint8 @obj-bytes = resample([ $obj-num ], 32, 8).reverse;
	my uint8 @gen-bytes = resample([ $gen-num ], 32, 8).reverse;
	my uint8 @obj-key = flat $.key.list, @obj-bytes[0 .. 2], @gen-bytes[0 .. 1], 0x73, 0x41, 0x6C, 0x54; # 'sAIT'

	$.md5( Buf.new(@obj-key) );
    }

    multi method crypt( Str $text, |c) {
	$.crypt( $text.encode("latin-1"), |c ).decode("latin-1");
    }

    multi method crypt( $bytes, Str :$mode! where 'encrypt'|'decrypt',
                        UInt :$obj-num!, UInt :$gen-num! ) is default {

        my $obj-key = self!object-key( $obj-num, $gen-num );
        self."$mode"( $obj-key, $bytes);
    }

    method encrypt( $key, $dec --> Buf) {
        my $iv = Buf.new( (^256).pick xx KeyLen );
        my $enc = $iv;
        $enc.append: self!aes-encrypt($key, $dec, :$iv );
        $enc;
    }

    method decrypt( $key, $enc-iv) {
        my $iv = Buf.new: $enc-iv[0 ..^ KeyLen];
        my @enc = +$enc-iv > KeyLen ?? $enc-iv[KeyLen .. *] !! [];
        self!aes-decrypt($key, Buf.new(@enc), :$iv );
    }

}
