package Date::Extract;
use strict;
use warnings;
use DateTime::Format::Natural;
use List::Util qw(min max);
use parent 'Class::Data::Inheritable';

__PACKAGE__->mk_classdata($_) for qw/scalar_downgrade handlers regex/;

sub _croak {
    require Carp;
    Carp::croak @_;
}

=head1 NAME

Date::Extract - simple date extraction

=head1 VERSION

Version 0.00 released ???

=cut

our $VERSION = '0.00';

=head1 SYNOPSIS

    my $parser = Date::Extract->new();
    my $dt = $parser->extract($arbitrary_text)
        or die "No date found.";
    return $dt->ymd;

=head1 MOTIVATION

There are already a few modules for getting a date out of a string.
L<DateTime::Format::Natural> should be your first choice. There's also
L<Time::ParseDate> which fits some very specific formats. Finally, you can
coerce L<Date::Manip> to do your bidding.

But I needed something that will take an arbitrary block of text, search it
for something that looks like a date string, and build a L<DateTime> object
out of it. This module fills this niche. By design it will produce few false
positives. This means it will not catch nearly everything that looks like a
date string.

=head1 METHODS

=head2 new PARAMHASH => C<Date::Extract>

=head3 arguments

=over 4

=item time_zone

Forces a particular time zone to be set (this actually matters, as "Tuesday"
on Monday at 11 PM means something different than "Tuesday" on Tuesday at 1
AM).

By default it will use the "floating" time zone. See the documentation for
L<DateTime>.

This controls both the input time zone and output time zone.

=item prefers

This argument decides what happens when an ambiguous date appears in the
input. For example, "Friday" may refer to any number of Fridays. The valid
options for this argument are:

=over 4

=item nearest

Prefer the nearest date. This is the default.

=item future

Prefer the closest future date.

=item past

Prefer the closest past date.

=back

=item returns

If the text has multiple possible dates, then this argument determines which
date will be returned. By default it's 'first'.

=over 4

=item first

Returns the first date found in the string.

=item last

Returns the final date found in the string.

=item earliest

Returns the date found in the string that chronologically precedes any other
date in the string.

=item latest

Returns the date found in the string that chronologically follows any other
date in the string.

=item all

Returns all dates found in the string, in the order they were found in the
strong.

=item all_cron

Returns all dates found in the string, in chronological order.

=back

=cut

sub new {
    my $class = shift;
    my %args = (
        returns => 'first',
        prefers => 'nearest',
        time_zone => 'Floating',
        @_,
    );

    if ($args{returns} ne 'first'
     && $args{returns} ne 'last'
     && $args{returns} ne 'earliest'
     && $args{returns} ne 'latest'
     && $args{returns} ne 'all'
     && $args{returns} ne 'all_cron') {
        _croak "Invalid `returns` passed to constructor: expected 'first', 'last', earliest', 'latest', 'all', or 'all_cron'.";
    }

    if ($args{prefers} ne 'nearest'
     && $args{prefers} ne 'past'
     && $args{prefers} ne 'future') {
        _croak "Invalid `prefers` passed to constructor: expected 'first', 'last', earliest', 'latest', 'all', or 'all_cron'.";
    }

    my $self = bless \%args, ref($class) || $class;

    return $self;
}

=for subclasses

This method will combine the arguments of parser->new and extract. Modify the
"to" hash directly.

=cut

sub _combine_args {
    shift;

    my $from = shift;
    my $to = shift;

    $to->{prefers}   ||= $from->{prefers};
    $to->{returns}   ||= $from->{returns};
    $to->{time_zone} ||= $from->{time_zone};
}

=head2 extract text => C<DateTime>, ARGS

Takes an arbitrary amount of text and extracts one or more dates from it. The
return value will be zero or more C<DateTime> objects. If called in scalar
context, the first will be returned, even if the C<returns> argument specifies
multiple possible return values.

See the documentation of C<new> for the configuration of this method. Any
arguments passed into this method will trump those from the parser.

You may reuse a parser for multiple calls to C<extract>.

You do not need to have an instantiated C<Date::Extract> object to call this
method. Just C<< Date::Extract->extract($foo) >> will work.

=cut

sub extract {
    my $self = shift;
    my $text = shift;
    my %args = @_;

    # combine the arguments of parser->new and this
    # don't do this if called as a class method
    $self->_combine_args($self, \%args)
        if ref($self);

    # when in scalar context, downgrade
    $args{returns} = $self->_downgrade($args{returns})
        unless wantarray;

    # do the work
    my @ret = $self->_extract($text, %args);

    # munge the output to match the desired return type
    return $self->_handle($args{returns}, @ret);
}

# build the giant regex used for parsing. it has to be a single regex, so that
# the order of matches is correct.
sub _build_regex {
    my $self = shift;

    my $relative          = '(?:today|tomorrow|yesterday)';

    my $long_weekday      = '(?:Monday|Tuesday|Wednesday|Thursday|Friday|Saturday|Sunday)';
    my $short_weekday     = '(?:Mon|Tue|Wed|Thu|Fri|Sat|Sun)';
    my $weekday           = "(?:$long_weekday|$short_weekday)";

    my $relative_weekday  = "(?:(?:next|previous|last)\\s*$weekday)";

    my $long_month        = '(?:January|February|March|April|May|June|July|August|September|October|November|December)';
    my $short_month       = '(?:Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sep|Oct|Nov|Dec)';
    my $month             = "(?:$long_month|$short_month)";

    # 1 - 31
    my $cardinal_monthday = "(?:[1-9]|[12][0-9]|3[01])";
    my $monthday          = "(?:$cardinal_monthday(?:st|nd|rd|th)?)";

    my $day_month         = "(?:$monthday\\s*$month)";
    my $month_day         = "(?:$monthday\\s*$month)";
    my $day_month_year    = "(?:(?:$day_month|$month_day)\\s*,\\s*\\d\\d\\d\\d)";

    my $yyyymmdd          = "(?:\\d\\d\\d\\d[-/]\\d\\d[-/]\\d\\d)";
    my $ddmmyy            = "(?:\\d\\d[-/]\\d\\d[-/]\\d\\d)";

    my $other             = $self->_build_more_regex;
    $other = "|$other"
        if $other;

    my $regex = qr{
        \b(
            $relative         # today
          | $relative_weekday # last Friday
          | $weekday          # Monday
          | $day_month_year   # November 13th, 1986
          | $day_month        # November 13th
          | $month_day        # 13 Nov
          | $yyyymmdd         # 1986/11/13
          | $ddmmyy           # 11-13-86
            $other            # anything from the subclass
        )\b
    }ix;

    $self->regex($regex);
}

# this is to be used in subclasses for adding more stuff to the regex
# for example, to add support for $foo_bar and $baz_quux, return
# "$foo_bar|$baz_quux"
sub _build_more_regex { '' }

# build the list->scalar downgrade types
sub _build_scalar_downgrade {
    my $self = shift;

    $self->scalar_downgrade({
        all      => 'first',
        earliest => 'all_cron',
    });
}

# build the handlers that munge the list of dates to the desired order
sub _build_handlers {
    my $self = shift;

    $self->handlers({
        all_cron => sub {
            sort { DateTime->compare_ignore_floating($a, $b) } @_
        },
        all      => sub { @_ },

        earliest => sub { min @_ },
        latest   => sub { max @_ },
        first    => sub { $_[0] },
        latest   => sub { $_[-1] },
    });
}

# actually perform the scalar downgrade
sub _downgrade {
    my $self    = shift;
    my $returns = shift;

    my $downgrades = $self->scalar_downgrade || $self->_build_scalar_downgrade;
    return $downgrades->{$returns} || $returns;
}

sub _handle {
    my $self    = shift;
    my $returns = shift;

    my $handlers = $self->handlers || $self->_build_handlers;
    my $handler = $handlers->{$returns};
    return defined $handler ? $handler->(@_) : @_
}

sub _extract {
    my $self = shift;
    my $text = shift;
    my %args = @_;

    my $regex = $self->regex || $self->_build_regex;
    my @gleaned = $text =~ /$regex/g;

    my %dtfn_args;
    $dtfn_args{prefer_future} = 1
        if $args{prefers} && $args{prefers} eq 'future';
    $dtfn_args{time_zone} = $args{time_zone};

    my $parser = DateTime::Format::Natural->new(%dtfn_args);
    my @ret;
    for (@gleaned) {
        my $dt = $parser->parse_datetime($_);
        push @ret, $dt->set_time_zone($args{time_zone})
            if $parser->success;
    }

    return @ret;
}

=head1 CAVEATS

This module is I<intentionally> very simple. Surprises are I<not> welcome
here.

=head1 SEE ALSO

L<DateTime::Format::Natural>, L<Time::ParseDate>, L<Date::Manip>

=head1 AUTHOR

Shawn M Moore, C<< <sartak at gmail.com> >>

=head1 BUGS

No known bugs at this point.

Please report any bugs or feature requests to
C<bug-date-extract at rt.cpan.org>, or through the web interface at
L<http://rt.cpan.org/NoAuth/ReportBug.html?Queue=Date-Extract>.
I will be notified, and then you'll automatically be notified of progress on
your bug as I make changes.

=head1 SUPPORT

You can find documentation for this module with the perldoc command.

    perldoc Date::Extract

You can also look for information at:

=over 4

=item * AnnoCPAN: Annotated CPAN documentation

L<http://annocpan.org/dist/Date-Extract>

=item * CPAN Ratings

L<http://cpanratings.perl.org/d/Date-Extract>

=item * RT: CPAN's request tracker

L<http://rt.cpan.org/NoAuth/Bugs.html?Dist=Date-Extract>

=item * Search CPAN

L<http://search.cpan.org/dist/Date-Extract>

=back

=head1 ACKNOWLEDGEMENTS

Thanks to Steven Schubiger for writing the fine L<DateTime::Format::Natural>.
We still use it, but it doesn't quite fill all the particular needs we have.

=head1 COPYRIGHT & LICENSE

Copyright 2007 Best Practical Solutions.

This program is free software; you can redistribute it and/or modify it
under the same terms as Perl itself.

=cut

1; # End of Date::Extract

