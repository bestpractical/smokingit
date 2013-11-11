use warnings;
use strict;

package Smokingit::Status;

sub new {
    my $class = shift;
    my ($smoke) = @_;
    my $self = bless { smoke => $smoke }, $class;
    $self->before;
    return $self;
}

sub before {
    my $self = shift;
    my $smoke = $self->{smoke};
    $self->{before} = [ $smoke->commit->status($smoke) ],
}

sub publish {
    my $self = shift;
    my $smoke = $self->{smoke};
    my $commit = $smoke->commit;

    my $before = $self->{before};
    my ($short, $long, $percent) = $commit->status($smoke);

    # Set up for next time
    $self->before;

    return unless $before->[0] ne $short
        or $before->[1] ne $long
            or ($before->[2]||"") ne ($percent||"");

    Jifty->bus->topic("test_progress")->publish( {
        type        => "test_progress",
        short_sha   => $commit->short_sha,
        sha         => $commit->sha,
        branch      => $smoke->branch_name,
        config_name => $smoke->configuration->name,
        config      => $smoke->configuration->id,
        smoke_id    => $smoke->id,
        raw_status  => $short,
        status      => $long,
        percent     => $percent,
    } );

    return if $before->[0] eq $short;

    Jifty->bus->topic("commit_status")->publish( {
        type       => "commit_status",
        sha        => $commit->sha,
        commit_id  => $commit->id,
        raw_status => $commit->status,
    } );

    if ($short eq "queued") {
        Jifty->bus->topic("test_queued")->publish( {
            type       => "test_queued",
            sha        => $commit->sha,
            config     => $smoke->configuration->id,
            smoke_id   => $smoke->id,
        } );
    }

    return unless $short =~ /^(errors|passing|failing|parsefail|todo)$/;
    Jifty->bus->topic("test_result")->publish( {
        type       => "test_result",
        sha        => $commit->sha,
        config     => $smoke->configuration->id,
        smoke_id   => $smoke->id,
        raw_status => $short,
        status     => $long,
    } );

    return unless $commit->is_fully_smoked;
    Jifty->bus->topic("commit_result")->publish( {
        type       => "commit_result",
        sha        => $commit->sha,
        commit_id  => $commit->id,
        raw_status => $commit->status,
    } );
}

1;
