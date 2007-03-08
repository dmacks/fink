# -*- mode: Perl; tab-width: 4; -*-
#
# Fink::SelfUpdate class
#
# Fink - a package manager that downloads source and installs it
# Copyright (c) 2001 Christoph Pfisterer
# Copyright (c) 2001-2007 The Fink Package Manager Team
#
# This program is free software; you can redistribute it and/or
# modify it under the terms of the GNU General Public License
# as published by the Free Software Foundation; either version 2
# of the License, or (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.	See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program; if not, write to the Free Software
# Foundation, Inc., 59 Temple Place - Suite 330, Boston, MA	 02111-1307, USA.
#

package Fink::SelfUpdate;

use Fink::Services qw(&execute);
use Fink::Bootstrap qw(&additional_packages);
use Fink::CLI qw(&print_breaking &prompt_boolean &prompt_selection);
use Fink::Config qw($config $basepath);
use Fink::Engine;  # &aptget_update &cmd_install, but they aren't EXPORT_OK
use Fink::Package;

use strict;
use warnings;

BEGIN {
	use Exporter ();
	our ($VERSION, @ISA, @EXPORT, @EXPORT_OK, %EXPORT_TAGS);
	$VERSION	 = 1.00;
	@ISA		 = qw(Exporter);
	@EXPORT		 = qw();
	@EXPORT_OK	 = qw();	# eg: qw($Var1 %Hashit &func3);
	%EXPORT_TAGS = ( );		# eg: TAG => [ qw!name1 name2! ],
}
our @EXPORT_OK;

END { }				# module clean-up code here (global destructor)


=head1 NAME

Fink::SelfUpdate - download package descriptions from server

=head1 DESCRIPTION

=head2 Methods

=over 4

=item check

  Fink::SelfUpdate::check($method);

This is the main entry point for the 'fink selfupdate*' commands. The
local collection of package descriptions is updated according to one
of the following methods:

=over 4

=item "point"

A tarball of the latest Fink binary installer package collection is
downloaded from the fink website.

=item "cvs"

=item "rsync"

"cvs" or "rsync" protocols are used to syncronize with a remote
server.

=back

The optional $method parameter specifies the
selfupdate method to use:

=over 4

=item 0 (or undefined or omitted)

Use the current method

=item 1 or "cvs"

Use the cvs method

=item 2 or "rsync"

Use the rsync method

=back

The current method is specified by name in the SelfUpdateMethod field
in the F<fink.conf> preference file. If there is no current method
preference and a specific $method is not given, the user is prompted
to select a method. If a $method is given that is not the same as the
current method preference, fink.conf is updated according to $method.

=cut

# TODO: auto-detect all available classes and their descs
our @known_method_classes = qw( rsync CVS point );
our %known_method_descs = (
	'rsync' => 'rsync',
	'CVS'   => 'cvs',
	'point' => 'Stick to point releases',
);

sub check {
	my $method = shift;  # requested selfupdate method to use

	$method = '' if ! defined $method;

	{
		# compatibility for old calling parameters
		my %methods = (
			0 => '',
			1 => 'cvs',
			2 => 'rsync',
		);
		if (length $method and exists $methods{$method}) {
			$method = $methods{$method};
		}
	}

	# canonical form is all-lower-case
	$method = lc($method);
	my $prev_method = lc($config->param_default("SelfUpdateMethod", ''));

	if ($method eq '') {
		# no explicit method requested

		if ($prev_method ne '') {
			# use existing default
			$method = $prev_method;
		} else {
			# no existing default so ask user

			$method = &prompt_selection(
				'Choose an update method',
				intro   => 'fink needs you to choose a SelfUpdateMethod.',
				default => [ 'value' => 'rsync' ],  # TODO: make sure this exists
				choices => [ map { $known_method_descs{$_} => lc($_) } @known_method_classes ]
			);
		}
	} else {
		# explicit method requested
		&print_breaking("\n Please note: the command 'fink selfupdate' "
						. "should be used for routine updating; you only "
						. "need to use a command like 'fink selfupdate-cvs' "
						. "or 'fink selfupdate-rsync' if you are changing "
						. "your update method. \n\n");

		if ($method ne $prev_method) {
			# requested a method different from previously-saved default
			# better double-check that user really wants to do this
			my $answer =
				&prompt_boolean("The current selfupdate method is $prev_method. "
								. "Do you wish to change this default method "
								. "to $method?",
								default => 1
				);
			return if !$answer;
		}
	}

	my ($subclass_use)  = grep { $method eq lc($_) } @known_method_classes;
	die "Selfupdate method '$method' is not implemented\n" unless( defined $subclass_use && length $subclass_use );

	$subclass_use = "Fink::SelfUpdate::$subclass_use";

	$subclass_use->system_check() or die "Selfupdate mthod '$method' cannot be used\n";

	if ($method ne $prev_method) {
		# save new selection (explicit change or being set for first time)
		&print_breaking("fink is setting your default update method to $method\n");
		$config->set_param("SelfUpdateMethod", $method);
		$config->save();
	}

	# clear remnants of any methods other than one to be used
	foreach my $subclass (map { "Fink::SelfUpdate::$_" } @known_method_classes) {
		next if $subclass eq $subclass_use;
		$subclass->stamp_clear();
		$subclass->clear_metadata();
	}

	# Let's do this thang!
	$subclass_use->do_direct();
	$subclass_use->stamp_set();
	&do_finish();
}

=item do_finish

  Fink::SelfUpdate::do_finish;

Perform some final actions after updating the package descriptions collection:

=over 4

=item 1.

Update apt indices

=item 2.

Reread package descriptions (update local package database)

=item 3.

If a new version of the "fink" package itself is available, install
that new version.

=item 4.

If a new fink was installed, relaunch this fink session using it.
Otherwise, do some more end-of-selfupdate tasks (see L<finish>).

=back

=cut

sub do_finish {
	my $package;

	# update the apt-get database
	Fink::Engine::aptget_update()
		or &print_breaking("Running 'fink scanpackages' may fix indexing problems.");

	# forget the package info
	Fink::Package->forget_packages();

	# ...and then read it back in
	Fink::Package->require_packages();

	# update the package manager itself first if necessary (that is, if a
	# newer version is available).
	$package = Fink::PkgVersion->match_package("fink");
	if (not $package->is_installed()) {
		Fink::Engine::cmd_install("fink");
	
		# re-execute ourselves before we update the rest
		print "Re-executing fink to use the new version...\n";
		exec "$basepath/bin/fink selfupdate-finish";
	
		# the exec doesn't return, but just in case...
		die "re-executing fink failed, run 'fink selfupdate-finish' manually\n";
	} else {
		# package manager was not updated, just finish selfupdate directly
		&finish();
	}
}

=item finish

  Fink::SelfUpdate::finish;

Update all the packages that are part of fink itself or that have an
Essential or other high importance.

=cut

sub finish {
	my (@elist);

	# determine essential packages
	@elist = Fink::Package->list_essential_packages();

	# add some non-essential but important ones
    my ($package_list, $perl_is_supported) = additional_packages();

	print_breaking("WARNING! This version of Perl ($]) is not currently supported by Fink.  Updating anyway, but you may encounter problems.\n") unless $perl_is_supported;

	foreach my $important (@$package_list) {
		my $po = Fink::Package->package_by_name($important);
		if ($po && $po->is_any_installed()) {
			# only worry about "important" ones that are already installed
			push @elist, $important;
		}
	}

	# update them
	Fink::Engine::cmd_install(@elist);	

	# tell the user what has happened
	print "\n";
	&print_breaking("The core packages have been updated. ".
					"You should now update the other packages ".
					"using commands like 'fink update-all'.");
	print "\n";
}

=back

=cut

### EOF
1;
# vim: ts=4 sw=4 noet
