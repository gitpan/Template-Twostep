#!/usr/bin/env perl
use strict;

use Test::More tests => 40;
use File::Spec::Functions qw(catdir catfile rel2abs splitdir);

#----------------------------------------------------------------------
# Load package

my @path = splitdir(rel2abs($0));
pop(@path);
pop(@path);

my $lib = catdir(@path, 'lib');
unshift(@INC, $lib);

require Template::Twostep;

#----------------------------------------------------------------------
# Create object

my $pp = Template::Twostep->new();
isa_ok($pp, "Template::Twostep"); # test 1
can_ok($pp, qw(new compile)); # test 2

#----------------------------------------------------------------------
# Test escaping


my $result = $pp->escape('< & >');
is($result, '&#60; & &#62;', "Escape"); # test 3

#----------------------------------------------------------------------
# Test render

my $data;
$result = $pp->render(\$data);
is($result, '', "Rendar undef"); # test 4

$data = \'<>';
$result = $pp->render($data);
is($result, '&#60;&#62;', "Rendar scalar"); # test 5

$data = [1, 2];
$result = $pp->render($data);
is($result, "<ul>\n<li>1</li>\n<li>2</li>\n</ul>", "Render array"); # test 6

$data = {a => 1, b => 2};
$result = $pp->render($data);
is($result, "<dl>\n<dt>a</dt>\n<dd>1</dd>\n<dt>b</dt>\n<dd>2</dd>\n</dl>",
   "Render hash"); # test 7

#----------------------------------------------------------------------
# Test type coercion

$data = $pp->coerce('$', 2);
is($$data, 2, "Coerce scalar to scalar"); # test 8

$data = $pp->coerce('@', 2);
is_deeply($data, [2], "Coerce scalar to array"); # test 9

$data = $pp->coerce('%', 2);
is($data, undef, "Coerce scalar to hash"); # test 10

$data = $pp->coerce('$');
is($$data, undef, "Coerce undef to scalar"); # test 11

$data = $pp->coerce('@');
is($data, undef, "Coerce undef to array"); # test 12

$data = $pp->coerce('%');
is($data, undef, "Coerce undef to hash"); # test 13

$data = $pp->coerce('$', [1, 3]);
is($$data, 2, "Coerce array to scalar"); # test 14

$data = $pp->coerce('@', [1, 3]);
is_deeply($data, [1, 3], "Coerce array to array"); # test 15

$data = $pp->coerce('%', [1, 3]);
is_deeply($data, {1 => 3}, "Coerce array to hash"); # test 16

$data = $pp->coerce('$', {1 => 3});
is($$data, 2, "Coerce hash to scalar"); # test 17

$data = $pp->coerce('@', {1 => 3});
is_deeply($data, [1, 3], "Coerce hash to array"); # test 18

$data = $pp->coerce('%', {1 => 3});
is_deeply($data, {1 => 3}, "Coerce hash to hash"); # test 19

#----------------------------------------------------------------------
# Test parse_block

my $template = <<'EOQ';
<!-- section header extra -->
Header
<!-- endsection header -->
<!-- set $i = 0 -->
<!-- for @data -->
  <!-- set $i = $i + 1 -->
  <!-- if $i % 2 -->
Even line
  <!-- else -->
Odd line
  <!-- endif -->
<!-- endfor -->
<!-- section footer -->
Footer
<!-- endsection footer -->
EOQ

my $sections = {};
my @lines = map {"$_\n"} split(/\n/, $template);
my @ok = grep {$_ !~ /section/} @lines;

my @block = $pp->parse_block($sections, \@lines, '');
my @sections = sort keys %$sections;

is_deeply(\@block, \@ok, "All lines returned from parse_block"); # test 20
is_deeply(\@sections, [qw(footer header)],
          "All sections returned from parse_block"); #test 21
is_deeply($sections->{footer}, ["Footer\n"],
          "Right value in footer from parse_block"); # test 22

my $subtemplate = <<'EOQ';
<!-- section header -->
Another Header
<!-- endsection -->
Another Body
<!-- section footer -->
Another Footer
<!-- endsection -->
EOQ

@lines = map {"$_\n"} split(/\n/, $template);
my @sublines = map {"$_\n"} split(/\n/, $subtemplate);
@ok = grep {$_ !~ /section/} @lines;
$ok[0] = "Another Header\n";
$ok[-1] = "Another Footer\n";

$sections = {};
@block = $pp->parse_block($sections, \@sublines, '');
@block = $pp->parse_block($sections, \@lines, '');

is_deeply(\@block, \@ok, "Template and subtemplate with parse_block"); # test 23
is_deeply($sections->{header}, ["Another Header\n"],
          "Right value in header for template & subtemplate"); # test 24

my $sub = $pp->compile($template, $subtemplate);
is(ref $sub, 'CODE', "compiled template"); # test 25

my $text = $sub->([1, 2]);
my $text_ok = <<'EOQ';
Another Header
Even line
Odd line
Another Footer
EOQ

is($text, $text_ok, "Run compiled template"); # test 26

$pp->{keep_sections} = 1;
@lines = map {"$_\n"} split(/\n/, $template);
@sublines = map {"$_\n"} split(/\n/, $subtemplate);

@block = $pp->parse_block($sections, \@sublines, '');
@block = $pp->parse_block($sections, \@lines, '');

is($block[0], "<!-- section header extra -->\n", "Keep sections start teag"); # test 27
is($block[2], "<!-- endsection header -->\n", "Keep sections start teag"); # test 28

$sub = $pp->compile($template, $subtemplate);
is(ref $sub, 'CODE', "compiled template with keep sections"); # test 29

$text = $sub->([1, 2]);
$text_ok = <<'EOQ';
<!-- section header extra -->
Another Header
<!-- endsection header -->
Even line
Odd line
<!-- section footer -->
Another Footer
<!-- endsection footer -->
EOQ

is($text, $text_ok, "Run ompiled template with keep sections"); # test 30

#----------------------------------------------------------------------
# Test configurable command start and end

$template = <<'EOQ';
/* set $x2 = 2 * $x */
2 * $x = $x2
EOQ

$pp = Template::Twostep->new(command_start => '/*', command_end => '*/');
$sub = $pp->compile($template);
$text = $sub->({x => 3});

is($text, "2 * 3 = 6\n", "Configurable start and end"); # test 31

#----------------------------------------------------------------------
# Test for loop

$template = <<'EOQ';
<!-- for @list -->
$name $sep $phone
<!-- endfor -->
EOQ

$sub = Template::Twostep->compile($template);
$data = {sep => ':', list => [{name => 'Ann', phone => '4444'},
                              {name => 'Joe', phone => '5555'}]};

$text = $sub->($data);

$text_ok = <<'EOQ';
Ann : 4444
Joe : 5555
EOQ

is($text, $text_ok, "For loop"); # test 32

#----------------------------------------------------------------------
# Test each loop

$template = <<'EOQ';
<ul>
<!-- each %hash -->
<li><b>$key</b> $value</li>
<!-- endeach -->
</ul>
EOQ

$sub = Template::Twostep->compile($template);
$data = {hash => {one => 1, two => 2, three => 3}};

$text = $sub->($data);
like($text, qr(<li><b>two</b> 2</li>), 'Each loop substitution'); # Test 33

my @match = $text =~ /(<li>)/g;
is(scalar @match, 3, 'Each loop count'); # Test 34

#----------------------------------------------------------------------
# Test with block

$template = <<'EOQ';
$a
<!-- with %hash -->
$a $b
<!-- endwith -->
$b
EOQ

$sub = Template::Twostep->compile($template);
$data = {a=> 1, b => 2, hash => {a => 10, b => 20}};

$text = $sub->($data);

$text_ok = <<'EOQ';
1
10 20
2
EOQ

is($text, $text_ok, "With block"); # test 35

#----------------------------------------------------------------------
# Test while loop

$template = <<'EOQ';
<!-- while $count -->
$count
<!-- set $count = $count - 1 -->
<!-- endwhile -->
go
EOQ

$sub = Template::Twostep->compile($template);
$data = {count => 3};

$text = $sub->($data);

$text_ok = <<'EOQ';
3
2
1
go
EOQ

is($text, $text_ok, "While loop"); # test 36

#----------------------------------------------------------------------
# Test if blocks

$template = <<'EOQ';
<!-- if $x == 1 -->
\$x is $x (one)
<!-- elsif $x  == 2 -->
\$x is $x (two)
<!-- else -->
\$x is unknown
<!-- endif -->
EOQ

$sub = Template::Twostep->compile($template);

$data = {x => 1};
$text = $sub->($data);
is($text, "\$x is 1 (one)\n", "If block"); # test 37

$data = {x => 2};
$text = $sub->($data);
is($text, "\$x is 2 (two)\n", "Elsif block"); # test 38

$data = {x => 3};
$text = $sub->($data);
is($text, "\$x is unknown\n", "Elsif block"); # test 39

#----------------------------------------------------------------------
# Create test directory

my $test = catdir(@path, 'test');
system("/bin/rm -rf $test");
mkdir $test;

$template = <<'EOQ';
<!-- section header -->
Dummy Header
<!-- endsection -->
<!-- for @data -->
$name $phone
<!-- endfor -->
<!-- section footer -->
Dummy Footer
<!-- endsection -->
EOQ

$subtemplate = <<'EOQ';
<!-- section header -->
Phone List
----
<!-- endsection -->

<!-- section footer -->
----
<!-- set $num = @data -->
$num people
<!-- endsection -->
EOQ

my $template_file = catfile($test, 'template.txt');
my $fd = IO::File->new($template_file, 'w');
print $fd $template;
close $fd;

my $subtemplate_file = catfile($test, 'subtemplate.txt');
$fd = IO::File->new($subtemplate_file, 'w');
print $fd $subtemplate;
close $fd;

$sub = Template::Twostep->compile($template_file, $subtemplate_file);

$data = [{name => 'Ann', phone => 4444},
         {name => 'Joe', phone => 5555}];

$text = $sub->($data);
$text_ok = <<'EOQ';
Phone List
----
Ann 4444
Joe 5555
----
2 people
EOQ

is($text, $text_ok, "Parse files"); # test 40

