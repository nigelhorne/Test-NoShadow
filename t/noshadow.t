#!perl -w
#
# t/noshadow.t - Test::NoShadow checking its own checkout, and the workspace of
# checkouts around it.
#
# Nothing here names a module or a distribution: the modules come from lib/, and
# the workspace is found from the test's own location. Use $Bin and not
# $RealBin throughout - for a symlinked .t, $Bin is the directory the link lives
# in, which is the distribution under test, while $RealBin is the one it points
# into, which may be a different distribution entirely.
#
# The workspace scan runs by default when this file is inside a workspace (the
# directory two levels up holding a Test-NoShadow checkout), and skips
# otherwise, so unpacking the release tarball anywhere is quiet:
#
#     NOSHADOW_WORKSPACE=/some/other/workspace prove -l t/noshadow.t
#
# %EXPECTED below is the ignore list: what this workspace shadows *today*. It is
# the reason the guard passes now and the reason it fails when something new
# appears - a shadow that is not listed there is a shadow nobody has looked at.
# NOSHADOW_IGNORE adds to it, colon-separated, for the day you move a checkout
# and the list below is stale.
#
# Test::NoShadow's two functions emit their own TAP through Test::Builder and
# return a boolean, so call them directly. Wrapping them in ok() double-counts
# the test and throws away the diagnostics they attach to the failure.

use strict;
use warnings;

use Test::Most;
use Test::Needs 'Test::NoShadow';	# skip cleanly where it isn't installed
use Test::NoShadow qw(lib_ok find_shadows);

use Cwd qw(abs_path);
use File::Find ();
use File::Spec;
use FindBin;

my $root = abs_path(File::Spec->catdir($FindBin::Bin, File::Spec->updir));
my $lib = File::Spec->catdir($root, 'lib');

my @modules = _modules_in($lib);

# The shallowest module in lib/ is the one the distribution is named after.
my ($main) = sort {
	($a =~ tr/://) <=> ($b =~ tr/://) or $a cmp $b
} @modules;

# The packages this workspace is expected to shadow. Each entry is matched against
# "provider/package", where the provider is the first directory beneath the
# workspace, and against the file's path.
my @EXPECTED = (
	# Second checkouts of a repository already here under its canonical name:
	# same git remote, so they provide the same packages by design.
	qr{\A(?:ged2ste-http-vwf|OHTTP_VWF|Nvwf|OBG)/},

	# Deployment trees: a site's own lib/, holding the modules it ships rather
	# than the distributions they are released in.
	qr{/dynamic-site/},
	qr{/www/},

	# Test fixtures and example applications: kept beside a distribution, not
	# shipped with it, and free to contain whatever the tests need.
	qr{/t/},
	qr{/examples/},

	# Two distributions that deliberately ship the same module, so installing
	# both is not a mistake.
	qr{\A(?:Genealogy-FindaGrave|WWW-Scrape-FindaGrave)/},

	# A package declared inside another module of the same distribution: in a
	# POD synopsis, or as a second package in the same file. No install order
	# can shadow anything, because only one of the files is the real module.
	qr{\AGeo-Coder-Free/Geo::Coder::Free::Display::index\z},
	qr{\A(?:HTTP-VWF|vwf)/VWF::Display::index\z},
	qr{\AMojolicious-Plugin-Buffer/MyApp::Lock\z},
	qr{\A(?:Sub-Private|Sub-Protected)/Foo\z},
);

subtest 'every module in this distribution was loaded from lib/' => sub {
	plan skip_all => "no .pm files found under $lib" unless @modules;

	# %INC is keyed by 'Foo/Bar.pm', so the modules have to be loaded by name;
	# require() on a file path would be recorded under the path instead and
	# lib_ok() would not find it.
	my @loaded;
	foreach my $module (@modules) {
		if(eval "require $module; 1") {
			push @loaded, $module;
		}
		else {
			# Not fatal: a module that cannot load standalone is a job for
			# Test::Compile, not for this test.
			(my $error = $@) =~ s/\s+\z//;
			diag("  $module did not load standalone, not checked: $error");
		}
	}

	plan skip_all => 'none of the modules under lib/ loaded' unless @loaded;

	# Fails if any of them came from site_perl or a sibling checkout instead of
	# this distribution's lib/ or blib/lib. Passes under prove -l and under
	# make test, which uses blib/lib.
	lib_ok(@loaded);
};

subtest 'the main module was loaded exactly once' => sub {
	plan skip_all => 'no modules found under lib/' unless defined($main);

	(my $rel = $main) =~ s/::/\//g;
	my @copies = grep { defined($_) && m{(?:\A|/)\Q$rel\E\.pm\z} } values %INC;

	is(scalar(@copies), 1, "exactly one $rel.pm is loaded");
	diag('  loaded from: ' . join(', ', @copies)) if @copies;
};

subtest 'nothing was loaded out of t/' => sub {
	# The other half of lib_ok()'s question: a copy vendored into t/ (or into
	# t/lib/, which many distributions put on @INC) must not win.
	my $tdir = File::Spec->catdir($root, 't');

	my @leaks = grep { _under($_, $tdir) } grep { defined } map { abs_path($_) || $_ } values %INC;

	is_deeply(\@leaks, [], 'no module was loaded out of t/')
		or diag(join("\n", map { "  $_" } @leaks));
};

SKIP: {
	my $workspace = _workspace();
	skip 'no workspace of checkouts around this one', 1 unless defined($workspace);

	subtest 'the workspace supplies no unexpected duplicate packages' => sub {
		# Any module this run pulled from inside the workspace but from
		# outside this distribution came from a sibling checkout: a stray -I
		# or a polluted PERL5LIB substituting a copy that is being edited for
		# the released version the tests are meant to exercise.
		my @leaks = grep {
			_under($_, $workspace) && !_under($_, $root)
		} grep { defined } map { abs_path($_) || $_ } values %INC;

		is_deeply(\@leaks, [], 'no module in this run came from a sibling checkout')
			or diag(join("\n", map { "  $_" } @leaks));

		my @ignore = (@EXPECTED,
			map { qr{\A\Q$_\E/} } grep { length } split /:/, ($ENV{'NOSHADOW_IGNORE'} // ''));

		my $all = find_shadows($workspace);
		my $real = find_shadows($workspace, { ignore => \@ignore });
		my ($before, $after) = (scalar(keys %$all), scalar(keys %$real));

		cmp_ok($after, '<=', $before, 'ignoring a provider cannot invent a shadow')
			or diag('the ignore list matched nothing - has the workspace moved?');

		diag(sprintf '%d shadowed package(s) under %s, %d once %d ignore pattern(s) are applied',
			$before, $workspace, $after, scalar(@ignore));

		# Every one of these is new since the list above was written, which is
		# either a duplicate worth knowing about or an ignore entry to add.
		is_deeply([sort keys %$real], [], 'no shadowed package outside the expected list');
		diag("unexpected shadow: $_") foreach (sort keys %$real);
	};
}

done_testing();

# Every module name under $lib, derived from the file layout.
sub _modules_in {
	my ($dir) = @_;

	return () unless -d $dir;

	my @modules;
	File::Find::find({
		no_chdir => 1,
		wanted => sub {
			return unless /\.pm\z/;
			my $rel = File::Spec->abs2rel($File::Find::name, $dir);
			$rel =~ s/\.pm\z//;
			$rel =~ s{[/\\]}{::}g;
			push @modules, $rel;
		},
	}, $dir);

	return sort @modules;
}

# The workspace of checkouts this distribution lives in, or undef. The default
# is the directory two levels up - the parent of this checkout - but only when
# it really does hold a Test-NoShadow checkout, so that a CPAN build directory
# or an unpacked tarball is skipped rather than scanned. NOSHADOW_WORKSPACE
# overrides it; '1' means the default.
sub _workspace {
	my $two_up = File::Spec->catdir($FindBin::Bin, File::Spec->updir, File::Spec->updir);
	my $env = $ENV{'NOSHADOW_WORKSPACE'};
	my $explicit = defined($env) && $env ne '1';
	my $dir = $explicit ? $env : $two_up;

	$dir = abs_path($dir) || $dir;
	unless(-d $dir) {
		diag("NOSHADOW_WORKSPACE=$dir is not a directory, skipping the workspace scan");
		return;
	}

	# Only the default needs checking. An explicit workspace is taken at its
	# word, so NOSHADOW_WORKSPACE can point at anything, a test fixture
	# included.
	unless($explicit) {
		my $checkout = File::Spec->catfile($dir, 'Test-NoShadow', 'lib', 'Test', 'NoShadow.pm');
		unless(-f $checkout) {
			diag("$dir holds no Test-NoShadow checkout, skipping the workspace scan");
			return;
		}
	}

	return $dir;
}

# Is $path inside $dir? Both must be absolute.
sub _under {
	my ($path, $dir) = @_;

	return 0 unless defined($path) && defined($dir);

	my $rel = File::Spec->abs2rel($path, $dir);

	return 0 if $rel =~ /\A\.\.(?:[\/\\]|\z)/;

	return !File::Spec->file_name_is_absolute($rel);
}
