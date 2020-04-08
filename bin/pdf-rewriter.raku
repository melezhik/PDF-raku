#!/usr/bin/env perl6
# Simple round trip read and rewrite a PDF
use v6;
use PDF::Reader;

#| rewrite a PDF or FDF and/or convert to/from JSON
sub MAIN(
    Str $file-in,               #= input PDF, FDF or JSON file (.json extension)
    Str $file-out = $file-in,   #= output PDF, FDF or JSON file (.json extension)
    Str  :$password  = '';      #= password for encrypted documents
    Bool :$repair    = False,   #= bypass and repair index. recompute stream lengths. Handy when
                                #= PDF files have been hand-edited.
    Bool :$rebuild  is copy,    #= rebuild object tree (renumber, garbage collect and deduplicate objects)
    Bool :$compress is copy,    #= compress streams
    Bool :$uncompress,          #= uncompress streams
    Str  :$class,               #= load a class (PDF::Class, PDF::Lite, PDF::API6)
    Bool :$decrypt   = False,   #= decrypt
    Bool :$drm       = True,
    ) {

    $compress = False if $uncompress;

    if $class {
        need PDF; # Could be PDF, FDF, PDF::Class, PDF::Lite, PDF::API6..
	my PDF $ = (require ::($class));
    }

    my PDF::Reader $reader .= new;

    note "opening {$file-in} ...";
    $reader.open( $file-in, :$repair, :$password );

    if $decrypt && $drm {
        with $reader.crypt {
            die "only the owner of this PDF can decrypt it"
                unless .is-owner;
        }
    }

    with $compress {
        note $_ ?? "compressing ..." !! "uncompressing ...";
        $reader.recompress(:compress($_));
    }
    elsif $decrypt {
        # ensure all objects have been loaded and decrypted
        $reader.get-objects;
    }

    if $decrypt {
        $reader.crypt = Nil;
        $reader.trailer<Encrypt>:delete;
        $rebuild //= True; # to expunge encryption dict
    }

    note "saving ...";
    my $writer = $reader.save-as($file-out, :$rebuild);
    note "done";

}

=begin pod

=head1 NAME

pdf-rewriter.raku - Rebuild a PDF using the L<PDF> module.

=head1 SYNOPSIS

pdf-rewriter.raku [options] file.pdf [out.pdf]
pdf-rewriter.raku [options] file.pdf [out.json] # convert to json
pdf-rewriter.raku [options] file.json [out.pdf] # convert from json

Options:
   --password    password for an encrypted PDF
   --repair      repair the input PDF
   --rebuild     rebuild object tree (renumber, garbage collect and deduplicate objects)
   --compress    compress streams
   --uncompress  uncompress streams, where possible
   --class=name  load L<PDF::Class> module
   --decrypt     remove encryption

=head1 DESCRIPTION

Rewrites the specified PDF document.

Input and output files may be either PDF or JSON.

=head1 SEE ALSO

L<PDF> (Perl 6)

=cut

=end pod
