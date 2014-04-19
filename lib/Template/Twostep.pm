package Template::Twostep;

use 5.008005;
use strict;
use warnings;
use integer;

use Carp;
use IO::File;

our $VERSION = "1.04";

#----------------------------------------------------------------------
# Create a new template engine

sub new {
    my ($pkg, %config) = @_;

    my $parameters = $pkg->parameters();
    my %self = (%$parameters, %config);

    my $self = bless(\%self, $pkg);
    $self->set_patterns();

    return $self;
}

#----------------------------------------------------------------------
# Coerce a value to the type indicated by the sigil

sub coerce {
    my ($self, $sigil, $value) = @_;

    my $data;
    if (defined $value) {
        my $ref = ref $value;
    
        if ($sigil eq '$') {
            if (! $ref) {
                $data = \$value;
            } elsif ($ref eq 'ARRAY') {
                my $val = @$value;
                $data = \$val;
            } elsif ($ref eq 'HASH') {
                my @data = %$value;
                my $val = @data;
                $data = \$val;
            }
    
        } elsif ($sigil eq '@') {
            if (! $ref) {
                $data = [$value];
            } elsif ($ref eq 'ARRAY') {
                $data = $value;
            } elsif ($ref eq 'HASH') {
                my @data = %$value;
                $data = \@data;
            }
    
        } elsif ($sigil eq '%') {
            if ($ref eq 'ARRAY' && @$value % 2 == 0) {
                my %data = @$value;
                $data = \%data;
            } elsif ($ref eq 'HASH') {
                $data = $value;
            }
        }

    } elsif ($sigil eq '$') {
        $data = \$value;
    }
    
    return $data;
}

#----------------------------------------------------------------------
# Compile a template into a subroutine which when called fills itself

sub compile {
    my ($pkg, @templates) = @_;
    my $self = ref $pkg ? $pkg : $pkg->new();

    # Template precedes subtemplate, which precedes subsubtemplate

    my @block;
    my $sections = {};
    while (my $template = pop(@templates)) {
        # If a template contains a newline, it is a string,
        # if not, it is a filename

        my @lines;
        if ($template =~ /\n/) {
            @lines = map {"$_\n"} split(/\n/, $template);

        } else {
            my $fd = IO::File->new($template, 'r');
            croak "Couldn't read $template: $!" unless $fd;

            @lines = <$fd>;
            close $fd;
        }

        @block = $self->parse_block($sections, \@lines, '');
    }

    return $self->construct_code(\@block);
}

#----------------------------------------------------------------------
# Construct a subroutine from the code embedded in the template

sub construct_code {
    my ($self, $lines) = @_;

    my $code = <<'EOQ';
sub {
$self->init_stack();
$self->push_stack(@_);
my $text = '';
EOQ

    push(@$lines, "\n");
    $code .= $self->parse_code($lines);

    $code .= <<'EOQ';
chomp $text;
return $text;
}
EOQ

    my $sub = eval ($code);
    croak $@ unless $sub;
    return $sub;
}

#----------------------------------------------------------------------
# Replace variable references with hashlist fetches

sub encode_expression {
    my ($self, $value) = @_;

    if (defined $value) {
        my $pre = '{$self->fetch_stack(\'';
        my $mid = '\',\'';
        my $post = '\')}';
        $value =~ s/(?<!\\)([\$\@\%])(\w+)/$1$pre$1$mid$2$post/g;

    } else {
        $value = '';
    }

    return $value;
}

#----------------------------------------------------------------------
# Replace variable references with hashlist fetches

sub encode_text {
    my ($self, $value) = @_;

    if (defined $value) {
        my $pre = '${$self->fill_in(\'';
        my $mid = '\',\'';
        my $post = '\')}';
        $value =~ s/(?<!\\)([\$\@\%])(\w+)/$pre$1$mid$2$post/g;

    } else {
        $value = '';
    }

    return $value;
}

#----------------------------------------------------------------------
# Escape a set of characters

sub escape {
    my ($self, $data) = @_;

    $data =~ s/($self->{escaped_chars_pattern})/'&#' . ord($1) . ';'/ge;
    return $data;
}

#----------------------------------------------------------------------
# Find and retrieve a value from the hash stack

sub fetch_stack {
    my ($self, $sigil, $name) = @_;

    my $value;
    for my $hash (@{$self->{stack}}) {
        if (exists $hash->{$name}) {
            $value = $hash->{$name};
            last;
        }
    }

    $value = $self->coerce($sigil, $value);
    croak "Illegal type conversion: $sigil$name" unless defined $value;

    return $value;
}

#----------------------------------------------------------------------
# Return a value to fill in a template

sub fill_in {
    my ($self, $sigil, $name) = @_;

    my $data = $self->fetch_stack($sigil, $name);
    my $result = $self->render($data);

    return \$result;
}

#----------------------------------------------------------------------
# Get the translation of a template command

sub get_command {
    my ($self, $cmd) = @_;

    my $commands = {
                    do => "%%;",
                    each => "while (my (\$k, \$v) = each %%) {\n" .
                            "\$self->push_stack({key=>\$k, value=>\$v});",
                    endeach => "\$self->pop_stack();\n}",
                    for => "foreach (%%) {\n\$self->push_stack(\$_);",
                	endfor => "\$self->pop_stack();\n}",
                    if => "if (%%) {",
                    elsif => "} elsif (%%) {",
                    else => "} else {",
                    endif => "}",
                    set => \&set_command,
                    while => "while (%%) {",
                    endwhile => "}",
                	with => "\$self->push_stack(\\%%);",
                    endwith => "\$self->pop_stack();",
                    };

    return $commands->{$cmd};
}

#----------------------------------------------------------------------
# Initialize the data stack

sub init_stack {
    my ($self) = @_;

    $self->{stack} = [];
    return;
}

#----------------------------------------------------------------------
# Is a command a singleton command?

sub is_singleton {
    my ($self, $cmd) = @_;

    return ! ($cmd eq 'section' || $self->get_command("end$cmd"));
}

#----------------------------------------------------------------------
# Set default parameters for package

sub parameters {
    my ($pkg) = @_;

    my $parameters = {
                      command_start => '<!-- ',
                      command_end => '-->',
                      escaped_chars => '<>',
                      keep_sections => 0,
                      };

    return $parameters;
}

#----------------------------------------------------------------------
# Read and check the template files

sub parse_block {
    my ($self, $sections, $lines, $command) = @_;

    my @block;
    while (defined (my $line = shift @$lines)) {
        my ($cmd, $arg) = $self->parse_command($line);

        if (defined $cmd) {
            if (substr($cmd, 0, 3) eq 'end') {
                $arg = substr($cmd, 3);
                croak "Mismatched block end ($command/$arg)"
                      if defined $arg && $arg ne $command;

                push(@block, $line);
                return @block;

            } elsif ($self->is_singleton($cmd)) {
                push(@block, $line);

            } else {
                my @sub_block = $self->parse_block($sections, $lines, $cmd);

                if ($cmd eq 'section') {
                    my $endline = pop(@sub_block);
                    my ($name, $rest) = split(' ', $arg, 2);

                    $sections->{$name} = \@sub_block
                        unless exists $sections->{$name};

                    if ($self->{keep_sections}) {
                        push(@block, $line, @{$sections->{$name}}, $endline);                        
                    } else {
                        push(@block, @{$sections->{$name}});
                    }

                } else {
                    push(@block, $line, @sub_block);
                }
            }

        } else {
            push(@block, $line);
        }
    }

    croak "Missing end" if $command;
    return @block;
}

#----------------------------------------------------------------------
# Parse the templace source

sub parse_code {
    my ($self, $lines) = @_;

    my $code = '';
    my $stash = '';

    while (defined (my $line = shift @$lines)) {
        my ($cmd, $arg) = $self->parse_command($line);

        if (defined $cmd) {
            if (length $stash) {
                $code .= "\$text .= <<\"EOQ\";\n";
                $code .= "${stash}EOQ\n";
                $stash = '';
            }

            my $command = $self->get_command($cmd);
            if (defined $command) {
                my $ref = ref ($command);
                if (! $ref) {
                    $arg = $self->encode_expression($arg);
                    $command =~ s/%%/$arg/;
                    $code .= "$command\n";
    
                } elsif ($ref eq 'CODE') {
                    $code .= $command->($self, $arg);
    
                } else {
                    die "I don't know how to handle a $ref: $cmd";
                }
            
            } else {
                $stash .=  $self->encode_text($line);
            }

        } else {
            $stash .= $self->encode_text($line);
        }
    }

    if (length $stash) {
        $code .= "\$text .= <<\"EOQ\";\n";
        $code .= "${stash}EOQ\n";
    }

    return $code;
}

#----------------------------------------------------------------------
# Parse a command and its argument

sub parse_command {
    my ($self, $line) = @_;

    if ($line =~ s/$self->{command_start_pattern}//) {
        $line =~ s/$self->{command_end_pattern}//;
        return split(' ', $line, 2)
    }

    return;
}

#----------------------------------------------------------------------
# Remove hash pushed on the stack

sub pop_stack {
    my ($self) = @_;
    return shift (@{$self->{stack}});
}

#----------------------------------------------------------------------
# Push one or more hashes on the stack

sub push_stack {
    my ($self, @hash) = @_;

    foreach my $hash (@hash) {
        my $newhash;
        if (ref $hash eq 'HASH') {
            $newhash = $hash;
        } else {
            $newhash = {data => $hash};
        }

        unshift (@{$self->{stack}}, $newhash);
    }

    return;
}

#----------------------------------------------------------------------
# Render a data structure as html

sub render {
    my ($self, $data) = @_;

    my $result;
    my $ref = ref $data;

    if ($ref eq 'SCALAR') {
        $result = defined $$data ? $self->escape($$data) : '';

    } elsif ($ref eq 'ARRAY') {
        my @result;
        foreach my $datum (@$data) {
            my $val = $self->render($datum);
            push(@result, "<li>$val</li>");
        }

        $result = join("\n", '<ul>', @result, '</ul>');

    } elsif ($ref eq 'HASH') {
        my @result;
        foreach my $key (sort keys %$data) {
            my $val = $self->render($data->{$key});
            push(@result, "<dt>$key</dt>", "<dd>$val</dd>");
        }

        $result = join("\n", '<dl>', @result, '</dl>');

    } else  {
        $result = $self->escape("$data");
    }


    return $result;
}

#----------------------------------------------------------------------
# Generate code for the set command, which stores results in the hashlist

sub set_command {
    my ($self, $arg) = @_;

    my ($var, $expr) = split (/\s*=\s*/, $arg, 2);
    $expr = $self->encode_expression($expr);

    return "\$self->store_stack(\'$var\', ($expr));\n";
}

#----------------------------------------------------------------------
# Set the regular expression patterns used to match a command

sub set_patterns {
    my ($self) = @_;

    $self->{command_start_pattern} = '^\s*' . quotemeta($self->{command_start});

    $self->{command_end_pattern} = quotemeta($self->{command_end}) . '\s*$';

    $self->{command_end_pattern} = '\s*' . $self->{command_end_pattern}
                if length $self->{command_end};

    $self->{escaped_chars_pattern} =
        '[' . quotemeta($self->{escaped_chars}) . ']';
            
    return;
}

#----------------------------------------------------------------------
# Store a variable in the hashlist, used by set

sub store_stack {
    my ($self, $var, @val) = @_;

    my ($sigil, $name) = $var =~ /([\$\@\%])(\w+)/;
    die "Unrecognized variable type: $name" unless defined $sigil;

    my $i;
    for ($i = 0; $i < @{$self->{stack}}; $i ++) {
        last if exists $self->{stack}[$i]{$name};
    }

    $i = 0 unless $i < @{$self->{stack}};

    if ($sigil eq '$') {
        my $val = @val == 1 ? $val[0] : @val;
        $self->{stack}[$i]{$name} = $val;

    } elsif ($sigil eq '@') {
        $self->{stack}[$i]{$name} = \@val;

    } elsif ($sigil eq '%') {
        my %val = @val;
        $self->{stack}[$i]{$name} = \%val;
    }

    return;
}

1;

=pod

=encoding utf-8

=head1 NAME

Template::Twostep - Compile templates into a subroutine

=head1 SYNOPSIS

    use Template::Twostep;
    my $tt = Template::Twostep->new;
    my $sub = $tt->compile($template, $subtemplate);
    my $output = $sub->($hash);

=head1 DESCRIPTION

This module simplifies the job of producing html text output by letting
you put data into a template. Templates support the control structures in
Perl: "for" and "while" loops, "if-else" blocks, and some others. Creating output
is a two step process. First you generate a subroutine from one or more
templates, then you call the subroutine with your data to generate the output.

The template format is line oriented. Commands occupy a single line and continue
to the end of line. By default commands are enclosed in html comments (<!--
-->), but the command start and end strings are configurable via the new method.
A command may be preceded by white space. If a command is a block command, it is
terminated by the word "end" followed by the command name. For example, the
"for" command is terminated by an "endfor" command and the "if" command by an
"endif" command.

All lines may contain variables. As in Perl, variables are a sigil character
('$,' '@,' or '%') followed by one or more word characters. For example,
C<$name> or C<@names>. To indicate a literal character instead of a variable,
precede the sigil with a backslash. When you run the subroutine that this module
generates, you pass it a reference, usually a reference to a hash, containing
some data. The subroutine replaces variables in the template with the value in
the field of the same name in the hash. If the types of the two disagree, the
code will coerce the data to the type of the sigil. You can pass a reference to
an array instead of a hash to the subroutine this module generates. If you do,
the template will use C<@data> to refer to the array.

There are several other template packages. I wrote this one to have the specific
set of features I want in a template package. First, I wanted templates to be
compiled into code. This approach has the advantage of speeding things up when
the same template is used more than once. However, it also poses a security risk
because code you might not want executed may be included in the template. For
this reason if the script using this module can be run from the web, make sure
the account that runs it cannot write to the template. I made the templates
command language line oriented rather than tag oriented to prevent spurious
white space from appearing in the output. Template commands and variables are
similar to Perl for familiarity. The power of the template language is limited
to the essentials for the sake of simplicity and to prevent mixing code with
presentation.

=head1 METHODS

This module has two public methods. The first, new, changes the module
defaults. Compile generates a subroutine from one or more templates. You Tthen
call this subroutine with a reference to the data you want to substitute into
the template to produce output.

Using subtemplates along with a template allows you to place the common design
elements in the template. You indicate where to replace parts of the template
with parts of the subtemplate by using the "section" command. If the template
contains a section block with the same name as a section block in the
subtemplates it replaces the contents inside the section block in the template
with the contents of the corresponding block in the subtemplate.

=over 4

=item C<$obj = Template::Twostep-E<gt>new(command_start =E<gt> '::', command_end =E<gt> '');>

Create a new parser. The configuration allows you to set a set of characters to
escape when found in the data (escaped_chars), the string which starts a command
(command_start), the string which ends a command (command_end), and whether
section commands are kept in the output (keep_sections). All commands end at the
end of line. However, you may wish to place commands inside comments and
comments may require a closing string. By setting command_end, the closing
string will be stripped from the end of the command.

=item C<$sub = $obj-E<gt>compile($template, $subtemplate);>

Generate a subroutine used to render data from a template and optionally from
one or more subtemplates. It can be invoked by an object created by a call to
new, or you can invoke it using the package name (Template::Twostep), in which
case it will first call new for you. If the template string does not contain a
newline, the method assumes it is a filename and it reads the template from that
file.

=back

=head1 TEMPLATE SYNTAX

If the first non-white characters on a line are the command start string, the
line is interpreted as a command. The command name continues up to the first
white space character. The text following the initial span of white space is the
command argument. The argument continues up to the command end string, or if
this is empty, to the end of the line.

Variables in the template have the same format as ordinary Perl variables,
a string of word characters starting with a sigil character. for example,

    $SUMMARY @data %dictionary

are examples of variables. The subroutine this module generates will substitute
values in the data it is passed for the variables in the template. New variables
can be added with the "set" command.

Arrays and hashes are rendered as unordered lists and definition lists when
interpolating them. This is done recursively, so arbitrary structures can be
rendered. This is mostly intended for debugging, as it does not provide fine
control over how the structures are rendered. For finer control, use the
commands described below so that the scalar fields in the structures can be
accessed. Scalar fields have the characters '<' and '>' escaped before
interpolating them. This set of characters can be changed by setting the
configuration parameter escaped chars. Undefined fields are replaced with the
empty string when rendering. If the type of data passed to the subroutine
differs from the sigil on the variable the variable is coerced to the type of
the sigil. This works the same as an assignment. If an array is referenced as a
scalar, the length of the array is output.

The following commands are supported in templates:

=over 4

=item do

The remainder of the line is interpreted as Perl code. For assignments, use
the set command.

=item each

Repeat the text between the "each" and "endeach" commands for each entry in the
hash table. The hast table key can be accessed through the variable $key and
the hash table value through the variable $value. Key-value pairs are returned
in random order. For example, this code displays the contents of a hash as a
list:

    <ul>
    <!-- each %hash -->
    <li><b>$key</b> $value</li>
    <!-- endeach -->
    </ul>

=item for

Expand the text between the "for" and "endfor" commands several times. The
"for" command takes a name of a field in a hash as its argument. The value of this
name should be a reference to a list. It will expand the text in the for block
once for each element in the list. Within the "for" block, any element of the list
is accessible. This is especially useful for displaying lists of hashes. For
example, suppose the data field name PHONELIST points to an array. This array is
a list of hashes, and each hash has two entries, NAME and PHONE. Then the code

    <!-- for @PHONELIST -->
    <p>$NAME<br>
    $PHONE</p>
    <!-- endfor -->

displays the entire phone list.

=item if

The text until the matching C<endif> is included only if the expression in the
"if" command is true. If false, the text is skipped. The "if" command can contain
an C<else>, in which case the text before the "else" is included if the
expression in the "if" command is true and the text after the "else" is included
if it is false. You can also place an "elsif" command in the "if" block, which
includes the following text if its expression is true.

    <!-- if $highlight eq 'y' -->
    <em>$text</em>
    <!-- else -->
    $text
    <!-- endif -->

=item section

If a template contains a section, the text until the endsection command will be
replaced by the section block with the same name in one the subtemplates. For
example, if the main template has the code

    <!-- section footer -->
    <div></div>
    <!-- endsection -->

and the subtemplate has the lines

    <!-- section footer -->
    <div>This template is copyright with a Creative Commons License.</div>
    <!-- endsection -->

The text will be copied from a section in the subtemplate into a section of the
same name in the template. If there is no block with the same name in the
subtemplate, the text is used unchanged.

=item set

Adds a new variable or updates the value of an existing variable. The argument
following the command name looks like any Perl assignment statement minus the
trailing semicolon. For example,

    <!-- set $link = "<a href=\"$url\">$title</a>" -->

=item while

Expand the text between the C<while> and C<endwhile> as long as the
expression following the C<while> is true.

    <!-- set $i = 10 -->
    <p>Countdown ...<br>
    <!-- while $i >= 0 -->
    $i<br>
    <!-- set $i = $i - 1 -->
    <!-- endwhile -->

=item with

Lists within a hash can be accessed using the "for" command. Hashes within a
hash are accessed using the "with" command. For example:

    <!-- with %address -->
    <p><i>$street<br />
    $city, $state $zip</i></p.
    <!-- endwith -->

=back

=head1 ERRORS

What to check when this module throws an error

=over 4

=item Couldn't read template

The template is in a file and the file could not be opened. Check the filename
and permissions on the file. Relative filenames can cause problems and the web
server is probably running another account than yours.

=item Illegal type conversion

The sigil on a variable differs from the data passed to the subroutine and
conversion. between the two would not be legal. Or you forgot to escape the '@'
in an email address by preceding it with a backslash.

=item Unknown command

Either a command was spelled incorrectly or a line that is not a command
begins with the command start string.

=item Missing end

The template contains a command for the start of a block, but
not the command for the end of the block. For example  an "if" command
is missing an "endif" command.

=item Mismatched block end

The parser found a different end command than the begin command for the block
it was parsing. Either an end command is missing, or block commands are nested
incorrectly.

=item Syntax error

The expression used in a command is not valid Perl.

=back

=head1 LICENSE

Copyright (C) Bernie Simon.

This library is free software; you can redistribute it and/or modify
it under the same terms as Perl itself.

=head1 AUTHOR

Bernie Simon E<lt>bernie.simon@gmail.comE<gt>

=cut
