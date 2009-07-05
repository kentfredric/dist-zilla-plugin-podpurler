package Dist::Zilla::Plugin::PodPurler;
# ABSTRACT: like PodWeaver, but more erratic and amateurish
use Moose;
use Moose::Autobox;
use List::MoreUtils qw(any);
with 'Dist::Zilla::Role::FileMunger';

=head1 WARNING

This code is really, really sketchy.  It's crude and brutal and will probably
break whatever it is you were trying to do.

Unlike L<Dist::Zilla::Plugin::PodWeaver|Dist::Zilla::Plugin::PodWeaver>, this
code will not get awesome.  In fact, it's just the old PodWeaver code, spun out
(no pun intended) so that RJBS can use it while he fixes PodWeaver-related
things.

=head1 DESCRIPTION

PodPurler ress, which rips apart your kinda-POD and reconstructs it as boring
old real POD.

=cut

sub munge_file {
  my ($self, $file) = @_;

  return $self->munge_pod($file)
    if $file->name =~ /\.(?:pm|pod)$/i
    and ($file->name !~ m{/} or $file->name =~ m{^lib/});

  return;
}

{
  package Dist::Zilla::Plugin::PodPurler::Eventual;
  our @ISA = 'Pod::Eventual';
  sub new {
    my ($class) = @_;
    require Pod::Eventual;
    bless [] => $class;
  }

  sub handle_event { push @{$_[0]}, $_[1] }
  sub events { @{ $_[0] } }
  sub read_string { my $self = shift; $self->SUPER::read_string(@_); $self }

  sub write_string {
    my ($self, $events) = @_;
    my $str = "\n=pod\n\n";

    EVENT: for my $event (@$events) {
      next EVENT if $event->{type} eq 'blank';

      if ($event->{type} eq 'verbatim') {
        $event->{content} =~ s/^/  /mg;
        $event->{type} = 'text';
      }

      if ($event->{type} eq 'text') {
        $str .= "$event->{content}\n";
        next EVENT;
      }
      $str .= "=$event->{command}";

      if( $event->{content} eq "\n" ){
          $str .= "\n\n";
          next EVENT;
      }

      if( length ( $event->{content} ) < 1 ){
          $str .= "\n";
          next EVENT;
      }

      $str .= " $event->{content}\n";
    }

    return $str;
  }
}

sub _h1 {
  my $name = shift;
  any { $_->{type} eq 'command' and $_->{content} =~ /^\Q$name\E$/m } @_;
}

sub munge_pod {
  my ($self, $file) = @_;

  require PPI;
  my $content = $file->content;
  my $doc = PPI::Document->new(\$content);
  my @pod_tokens = map {"$_"} @{ $doc->find('PPI::Token::Pod') || [] };
  $doc->prune('PPI::Token::Pod');

  my $pe = 'Dist::Zilla::Plugin::PodPurler::Eventual';

  if ($pe->new->read_string("$doc")->events) {
    $self->log(
      sprintf "can't invoke %s on %s: there is POD inside string literals",
        $self->plugin_name, $file->name
    );
    return;
  }

  my @pod = $pe->new->read_string(join "\n", @pod_tokens)->events;

  unless (_h1(VERSION => @pod)) {
    unshift @pod, (
      { type => 'command', command => 'head1', content => "VERSION\n"  },
      { type => 'text',   
        content => sprintf "version %s\n", $self->zilla->version }
    );
  }

  unless (_h1(NAME => @pod)) {
    Carp::croak "couldn't find package declaration in " . $file->name
      unless my $pkg_node = $doc->find_first('PPI::Statement::Package');
    my $package = $pkg_node->namespace;

    $self->log("couldn't find abstract in " . $file->name)
      unless my ($abstract) = $doc =~ /^\s*#+\s*ABSTRACT:\s*(.+)$/m;

    my $name = $package;
    $name .= " - $abstract" if $abstract;

    unshift @pod, (
      { type => 'command', command => 'head1', content => "NAME\n"  },
      { type => 'text',                        content => "$name\n" },
    );
  }

  my (@methods, $in_method);

  $self->_regroup($_->[0] => $_->[1] => \@pod)
    for ( [ attr => 'ATTRIBUTES' ], [ method => 'METHODS' ] );

  unless (_h1(AUTHOR => @pod) or _h1(AUTHORS => @pod)) {
    my @authors = $self->zilla->authors->flatten;
    my $name = @authors > 1 ? 'AUTHORS' : 'AUTHOR';

    push @pod, (
      { type => 'command',  command => 'head1', content => "$name\n" },
      { type => 'verbatim',
        content => join("\n", @authors) . "\n"
      }
    );
  }

  unless (_h1(COPYRIGHT => @pod) or _h1(LICENSE => @pod)) {
    push @pod, (
      { type => 'command', command => 'head1',
        content => "COPYRIGHT AND LICENSE\n" },
      { type => 'text', content => $self->zilla->license->notice }
    );
  }

  @pod = grep { $_->{type} ne 'command' or $_->{command} ne 'cut' } @pod;
  push @pod, { type => 'command', command => 'cut', content => "\n" };

  my $newpod = $pe->write_string(\@pod);

  my $end = do {
    my $end_elem = $doc->find('PPI::Statement::Data')
                || $doc->find('PPI::Statement::End');
    join q{}, @{ $end_elem || [] };
  };

  $doc->prune('PPI::Statement::End');
  $doc->prune('PPI::Statement::Data');

  my $docstr = $doc->serialize;

  $content = $end
           ? "$docstr\n\n$newpod\n\n$end"
           : "$docstr\n__END__\n$newpod\n";

  $file->content($content);
}

sub _regroup {
  my ($self, $cmd, $header, $pod) = @_;

  my @items;
  my $in_item;

  EVENT: for (my $i = 0; $i < @$pod; $i++) {
    my $event = $pod->[$i];

    if ($event->{type} eq 'command' and $event->{command} eq $cmd) {
      $in_item = 1;
      push @items, splice @$pod, $i--, 1;
      next EVENT;
    }

    if (
      $event->{type} eq 'command'
      and $event->{command} !~ /^(?:over|item|back|head[3456])$/
    ) {
      $in_item = 0;
      next EVENT;
    }

    push @items, splice @$pod, $i--, 1 if $in_item;
  }
      
  if (@items) {
    unless (_h1($header => @$pod)) {
      push @$pod, {
        type    => 'command',
        command => 'head1',
        content => "$header\n",
      };
    }

    $_->{command} = 'head2'
      for grep { ($_->{command}||'') eq $cmd } @items;

    push @$pod, @items;
  }
}

__PACKAGE__->meta->make_immutable;
no Moose;
1;
