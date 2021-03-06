package App::PRT::Command::RenameClass;
use strict;
use warnings;
use PPI;
use Path::Class;

sub new {
    my ($class) = @_;
    bless {
        rule => undef,
    }, $class;
}

sub handle_files { 1 }

# parse arguments from CLI
# arguments:
#   @arguments
# returns:
#   @rest_arguments
sub parse_arguments {
    my ($self, @arguments) = @_;

    die "source and destination class are required" unless @arguments >= 2;

    $self->register(shift @arguments => shift @arguments);

    @arguments;
}


# register a replacing rule
# arguments:
#   $source: source class name
#   $dest:   destination class name
sub register {
    my ($self, $source_class_name, $destination_class_name) = @_;

    $self->{source_class_name} = $source_class_name;
    $self->{destination_class_name} = $destination_class_name;
}

sub source_class_name {
    my ($self) = @_;

    $self->{source_class_name};
}

sub destination_class_name {
    my ($self) = @_;

    $self->{destination_class_name};
}

# refactor a file
# argumensts:
#   $file: filename for refactoring
# todo:
#   - support package block syntax
#   - multi packages in one file
sub execute {
    my ($self, $file) = @_;

    my $replaced = 0;

    my $document = PPI::Document->new($file);

    my $package_statement_renamed = $self->_try_rename_package_statement($document);

    $replaced += $self->_try_rename_includes($document);

    $replaced += $self->_try_rename_parent_class($document);

    $replaced += $self->_try_rename_quotes($document);

    $replaced += $self->_try_rename_tokens($document);

    if ($package_statement_renamed) {
        $document->save($self->_destination_file($file));
        unlink($file);
    } else {
        return unless $replaced;
        $document->save($file);
    }
}

sub _try_rename_package_statement {
    my ($self, $document) = @_;

    my $package = $document->find_first('PPI::Statement::Package');

    return unless $package;
    return unless $package->namespace eq $self->source_class_name;

    my $namespace = $package->schild(1);

    return unless $namespace->isa('PPI::Token::Word');

    $namespace->set_content($self->destination_class_name);
    1;
}

sub _try_rename_includes {
    my ($self, $document) = @_;

    my $replaced = 0;

    my $statements = $document->find('PPI::Statement::Include');
    return 0 unless $statements;

    for my $statement (@$statements) {
        next unless defined $statement->module;
        next unless $statement->module eq $self->source_class_name;

        my $module = $statement->schild(1);

        return unless $module->isa('PPI::Token::Word');

        $module->set_content($self->destination_class_name);
        $replaced++;
    }

    $replaced;
}

sub _try_rename_quotes {
    my ($self, $document) = @_;

    my $replaced = 0;

    my $quotes = $document->find('PPI::Token::Quote');
    return 0 unless $quotes;

    for my $quote (@$quotes) {
        next unless $quote->string eq $self->source_class_name;
        $quote->set_content("'@{[ $self->destination_class_name ]}'");

        $replaced++;
    }

    $replaced;
}

# TODO: too complicated
sub _try_rename_parent_class {
    my ($self, $document) = @_;

    my $replaced = 0;

    my $includes = $document->find('PPI::Statement::Include');
    return 0 unless $includes;

    for my $statement (@$includes) {
        next unless defined $statement->pragma;
        next unless $statement->pragma ~~ [qw(parent base)]; # only 'use parent' and 'use base' are supported

        # schild(2) is 'Foo' of use parent Foo
        my $parent = $statement->schild(2);

        if ($parent->isa('PPI::Token::Quote')) {
            if ($parent->literal eq $self->source_class_name) {
                $parent->set_content("'@{[ $self->destination_class_name ]}'");
                $replaced++;
            }
        } elsif ($parent->isa('PPI::Token::QuoteLike::Words')) {
            # use parent qw(A B C) pattern
            # literal is array when QuoteLike::Words
            my $_replaced = 0;
            my @new_literal = map {
                if ($_ eq $self->source_class_name) {
                    $_replaced++;
                    $self->destination_class_name;
                } else {
                    $_;
                }
            } $parent->literal;
            if ($_replaced) {
                $parent->set_content('qw(' . join(' ', @new_literal) . ')');
                $replaced++;
            }
        }
    }

    $replaced;
}

# discussions:
#   seems too wild
sub _try_rename_tokens {
    my ($self, $document) = @_;

    my $replaced = 0;

    my $tokens = $document->find('PPI::Token');
    return 0 unless $tokens;

    for my $token (@$tokens) {
        next unless $token->content eq $self->source_class_name;
        $token->set_content($self->destination_class_name);
        $replaced++;
    }

    $replaced;
}

sub _destination_file {
    my ($self, $file) = @_;

    my @delimiters = do {
        my $pattern = $self->source_class_name;
        $pattern =~ s{::}{(.+)}g;
        ($file =~ qr/^(.*)$pattern(.*)$/);
    };
    my $prefix = shift @delimiters;
    my $suffix = pop @delimiters;

    my $fallback_delimiter = $delimiters[-1];
    my $dir = file($file)->dir;
    $dir = $dir->parent for grep { $_ eq '/' } @delimiters;
    my $basename = $self->destination_class_name;
    $basename =~ s{::}{
        shift @delimiters // $fallback_delimiter;
    }ge;
    $dir->file("$basename$suffix");
}

1;
