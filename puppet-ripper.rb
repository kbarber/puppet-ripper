#!/usr/bin/env ruby

require 'ripper'
require 'pp'
require 'json'

class Mod
  attr_reader :path

  def initialize(dir)
    @path = File.expand_path(dir)
  end

  def types
    files = Dir.chdir(types_path) do
      Dir.glob(types_path + '/*.rb')
    end
    files.map do |f|
      Type.new(self, f)
    end
  end

  # @api private
  def types_path
    File.join(path, 'lib', 'puppet', 'type')
  end

  def modulefile
    Modulefile.new(self, File.join(path, "Modulefile"))
  end
end

class Modulefile
  attr_reader :mod, :path

  def initialize(mod, path)
    @mod = mod
    @path = path
  end

  def sexp
    Ripper.sexp(File.read(@path))
  end

  def sexp_main_block
    program = sexp[1]

    vals = {}
    program.each do |s|
      if s[0] == :command and
         s[1][0] == :@ident and
         s[2][0] == :args_add_block

        name = s[1][1]
        # TODO: accept multiple values
        value = s[2][1][0][1][1][1]

        vals[name] = value
      end
    end

    return vals
  end

  def method_missing(meth, *val)
    sexp_main_block[meth.to_s]
  end
end

class Type
  attr_reader :mod, :path, :name

  def initialize(mod, path)
    @path = path
    @name = path.split("/")[-1].split(".")[0]
    @mod = mod
  end

  def sexp
    Ripper.sexp(File.read(@path))
  end

  # Extract the block from the newtype declaration
  #
  # @api private
  def sexp_newtype_block
    program = sexp[1]

    program.each do |s|
      if s[0] == :method_add_block and
         s[1][0] == :method_add_arg and
         s[1][1][0] == :call and
         s[1][1][1][0] == :const_path_ref and
         s[1][1][1][1][0] == :var_ref and
         s[1][1][1][1][1][0..1] == [:@const, "Puppet"] and
         s[1][1][1][2][0..1] == [:@const, "Type"] and
         s[1][1][3][0..1] == [:@ident, "newtype"] and
         s[2][0] == :do_block

        return s[2][2]
      end
    end

    nil
  end

  # Extract the @doc declaration from the type
  def doc
    sexp_newtype_block.each do |s|
      if s[0] == :assign and
         s[1][0] == :var_field and
         s[1][1][0..1] == [:@ivar, "@doc"]
        return s[2][1][1][1]
      end
    end
  end

  # Extra a hash of features from the type
  def features
    features = {}
    sexp_newtype_block.each do |s|
      if s[0] == :command and
         s[1][0..1] == [:@ident, "feature"] and
         s[2][0] == :args_add_block

        name = s[2][1][0][1][1][1]
        desc = s[2][1][1][1][1][1]

        features[name] = desc
      end
    end

    features
  end

  def params
    params = {}

    sexp_newtype_block.each do |s|
      if s[0] == :method_add_block and
         s[1][0] == :method_add_arg and
         s[1][1][0] == :fcall and
         s[1][1][1][0..1] == [:@ident, "newparam"]

        name = s[1][2][1][1][0][1][1][1]
        desc = s[2][2][0][2][1][0][1][1][1]

        params[name] = desc
      end
    end

    params
  end

  def properties
    props = {}

    sexp_newtype_block.each do |s|
      if s[0] == :method_add_block and
         s[1][0] == :method_add_arg and
         s[1][1][0] == :fcall and
         s[1][1][1][0..1] == [:@ident, "newproperty"]

        name = s[1][2][1][1][0][1][1][1]
        desc = s[2][2][0][2][1][0][1][1][1]

        props[name] = desc
      end
    end

    props
  end

  def providers
    files = Dir.chdir(providers_path) do
      Dir.glob(providers_path + '/*.rb')
    end
    files.map do |f|
      Provider.new(self, f)
    end
  end

  def providers_path
    File.join(mod.path, 'lib', 'puppet', 'provider', name)
  end
end

class Provider
  attr_reader :path, :type, :name

  def initialize(type, path)
    @path = path
    @type = type
    @name = path.split("/")[-1].split(".")[0]
  end

  def sexp
    Ripper.sexp(File.read(path))
  end

  # Extract the block from the provide declaration
  #
  # @api private
  def sexp_provide_block
    program = sexp[1]

    program.each do |s|
      if s[0] == :method_add_block and
         s[1][0] == :command_call and
         s[1][1][0] == :method_add_arg and
         s[1][1][1][0] == :call and
         s[1][1][1][1][0] == :const_path_ref and
         s[1][1][1][1][1][0] == :var_ref and
         s[1][1][1][1][1][1][0..1] == [:@const, "Puppet"] and
         s[1][1][1][1][2][0..1] == [:@const, "Type"] and
         s[1][1][1][3][0..1] == [:@ident, "type"] and
         s[2][0] == :do_block

        return s[2][2]
      end
    end

    nil
  end

  def features
    f = []
    sexp_provide_block.each do |s|
      if s[0] == :command and
         s[1][0..1] == [:@ident, "has_feature"]

        f << s[2][1][0][1][1][1]
      end
    end
    f
  end

  def doc
    sexp_provide_block.each do |s|
      if s[0] == :assign and
         s[1][0] == :var_field and
         s[1][1][0..1] == [:@ivar, "@doc"]

        return s[2][1][1][1]
      end
    end
  end
end

# Create new module instance to work with
pr = Mod.new(ARGV[0])
mf = pr.modulefile

# Work out types part of hash
types = pr.types.map do |t|
  h = {}

  h["name"] = t.name
  h["doc"] = t.doc

  h["parameters"] = []
  t.params.each do |k,v|
    h["parameters"] << {
      "name" => k,
      "doc" => v,
    }
  end

  h["properties"] = []
  t.properties.each do |k,v|
    h["properties"] << {
      "name" => k,
      "doc" => v,
    }
  end

  h["providers"] = t.providers.map do |p|
    {
      "name" => p.name,
      "doc" => p.doc,
    }
  end

  h
end

main = {
  "dependencies" => mf.dependencies,
  "summary" => mf.summary,
  "description" => mf.description,
  "version" => mf.version,
  "license" => mf.license,
  "author" => mf.author,
  "source" => mf.source,
  "name" => mf.name,
  "checksums" => {},
  "types" => types,
}

jj main
