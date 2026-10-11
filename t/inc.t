use strict;
use warnings;

use Test::Tester;	# must be loaded before Test::Builder
use Test::Most;
use File::Path qw(make_path);
use File::Spec;
use File::Temp qw(tempdir);
use Test::NoShadow qw(shadowed_ok);

sub write_pm {
	my ($root, $package) = @_;

	my @parts = split(/::/, $package);
	my $file = File::Spec->catfile($root, 'lib', @parts[0 .. $#parts - 1], "$parts[-1].pm");
	make_path((File::Spec->splitpath($file))[1]);
	open(my $fh, '>', $file) or die "Cannot open $file: $!";
	print $fh "package $package;\n\nuse strict;\nuse warnings;\n\n1;\n";
	close($fh);
}

subtest 'a single @INC entry is clean' => sub {
	my $root = tempdir(CLEANUP => 1);
	write_pm($root, 'Foo::Bar');

	my ($premature, @results) = run_tests(sub {
		local @INC = ($root);
		shadowed_ok();
	});

	is($results[0]{ok}, 1, 'shadowed_ok() with no arguments scans @INC and passes');
};

subtest 'the same package in two @INC entries is shadowed' => sub {
	my $root1 = tempdir(CLEANUP => 1);
	my $root2 = tempdir(CLEANUP => 1);
	write_pm($root1, 'Foo::Bar');
	write_pm($root2, 'Foo::Bar');

	my ($premature, @results) = run_tests(sub {
		local @INC = ($root1, $root2);
		shadowed_ok();
	});

	is($results[0]{ok}, 0, 'fails when two @INC entries provide the same package');

	my $diag = $results[0]{diag} || '';
	like($diag, qr/Foo::Bar is provided by 2 files:/, 'names the package');
	like($diag, qr/Foo.Bar\.pm/, 'names the files');
};

done_testing();
