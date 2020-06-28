# frozen_string_literal: true

require 'asciidoctor/extensions' unless RUBY_ENGINE == 'opal'
require 'stringio'
require 'zlib'
require 'digest'
require 'fileutils'

# Asciidoctor extensions
#
module AsciidoctorExtensions
  include Asciidoctor

  # A block extension that converts a diagram into an image.
  #
  class KrokiBlockProcessor < Extensions::BlockProcessor
    use_dsl

    on_context :listing, :literal
    name_positional_attributes 'target', 'format'

    def process(parent, reader, attrs)
      diagram_type = @name
      diagram_text = reader.string
      KrokiProcessor.process(self, parent, attrs, diagram_type, diagram_text)
    end
  end

  # A block macro extension that converts a diagram into an image.
  #
  class KrokiBlockMacroProcessor < Asciidoctor::Extensions::BlockMacroProcessor
    use_dsl

    def process(parent, target, attrs)
      diagram_type = @name
      target = parent.apply_subs(target, ['attributes'])
      diagram_text = read(target)
      KrokiProcessor.process(self, parent, attrs, diagram_type, diagram_text)
    end

    def read(target)
      if target.start_with?('http://') || target.start_with?('https://')
        require 'open-uri'
        URI.open(target, &:read)
      else
        File.open(target, &:read)
      end
    end
  end

  # Internal processor
  #
  class KrokiProcessor
    class << self
      def process(processor, parent, attrs, diagram_type, diagram_text)
        doc = parent.document
        # If "subs" attribute is specified, substitute accordingly.
        # Be careful not to specify "specialcharacters" or your diagram code won't be valid anymore!
        if (subs = attrs['subs'])
          diagram_text = parent.apply_subs(diagram_text, parent.resolve_subs(subs))
        end
        title = attrs.delete('title')
        caption = attrs.delete('caption')
        attrs.delete('opts')
        role = attrs['role']
        format = get_format(doc, attrs, diagram_type)
        attrs['role'] = get_role(format, role)
        attrs['alt'] = get_alt(attrs)
        attrs['target'] = create_image_src(doc, diagram_type, format, diagram_text)
        attrs['format'] = format
        block = processor.create_image_block(parent, attrs)
        block.title = title
        block.assign_caption(caption, 'figure')
        block
      end

      private

      def get_alt(attrs)
        if (title = attrs['title'])
          title
        elsif (target = attrs['target'])
          target
        else
          'Diagram'
        end
      end

      def get_role(format, role)
        if role
          if format
            "#{role} kroki-format-#{format} kroki"
          else
            "#{role} kroki"
          end
        else
          'kroki'
        end
      end

      def get_format(doc, attrs, diagram_type)
        format = attrs['format'] || 'svg'
        # The JavaFX preview doesn't support SVG well, therefore we'll use PNG format...
        if doc.attr?('env-idea') && format == 'svg'
          # ... unless the diagram library does not support PNG as output format!
          # Currently, mermaid, nomnoml, svgbob, wavedrom only support SVG as output format.
          svg_only_diagram_types = %w[:mermaid :nomnoml :svgbob :wavedrom]
          format = 'png' unless svg_only_diagram_types.include?(diagram_type)
        end
        format
      end

      def create_image_src(doc, type, format, text)
        data = Base64.urlsafe_encode64(Zlib::Deflate.deflate(text, 9))
        "#{server_url(doc)}/#{type}/#{format}/#{data}"
      end

      def server_url(doc)
        doc.attr('kroki-server-url') || 'https://kroki.io'
      end
    end
  end

  class KrokiDiagram
    def initialize(type, format, text)
      @text = text
      @type = type
      @format = format
    end

    def get_diagram_uri (server_url)
      "#{server_url}/#{@type}/#{@format}/#{encode}"
    end

    def encode
      Base64.urlsafe_encode64(Zlib::Deflate.deflate(@text, 9))
    end

    def save(doc, target, kroki_client)
      dir_path = dir_path(doc)
      diagram_url = get_diagram_uri(kroki_client.get_server_url)
      diagram_name = "diag-#{Digest::SHA256.hexdigest diagram_url}.#{@format}"
      file_path = File.join(dir_path, diagram_name)
      encoding = if @format == 'txt' || @format == 'atxt' || @format == 'utxt'
                   'utf8'
                 elsif @format == 'svg'
                   'binary'
                 else
                   'binary'
                 end
      # file is either (already) on the file system or we should read it from Kroki
      contents = File.exist?(file_path) ? read(file_path) : kroki_client.get_image(self, encoding)
      FileUtils.mkdir_p(dir_path)
      if encoding == 'binary'
        File.binwrite(file_path, contents)
      else
        File.write(file_path, contents)
      end
      diagram_name
    end

    def read(target)
      if target.start_with?('http://') || target.start_with?('https://')
        require 'open-uri'
        URI.open(target, &:read)
      else
        File.open(target, &:read)
      end
    end

    def dir_path(doc)
      images_output_dir = doc.attr('imagesoutdir')
      out_dir = doc.attr('outdir')
      to_dir = doc.attr('to_dir')
      base_dir = doc.base_dir
      images_dir = doc.attr('imagesdir', '')
      if images_output_dir
        images_output_dir
      elsif out_dir
        File.join(out_dir, images_dir)
      elsif to_dir
        File.join(to_dir, images_dir)
      else
        File.join(base_dir, images_dir)
      end
    end
  end

  class KrokiClient
    def initialize(doc, http_client)
      @max_uri_length = 4096
      @http_client = http_client
      method = doc.attr('kroki-http-method', 'adaptive').downcase
      if @method == 'get' || @method == 'post' || @method == 'adaptive'
        @method = method
      else
        puts "Invalid value '#{method}' for kroki-http-method attribute. The value must be either: 'get', 'post' or 'adaptive'. Proceeding using: 'adaptive'."
        @method = 'adaptive'
      end
      @doc = doc
    end

    def text_content(kroki_diagram)
      get_image(kroki_diagram, 'utf-8')
    end

    def get_image(kroki_diagram, encoding)
      server_url = get_server_url
      type = kroki_diagram.type
      format = kroki_diagram.format
      text = kroki_diagram.text
      if @method == 'adaptive' || @method == 'get'
        uri = kroki_diagram.get_diagram_uri(server_url)
        if uri.length > @max_uri_length
          # The request URI is longer than 4096.
          if @method == 'get'
            # The request might be rejected by the server with a 414 Request-URI Too Large.
            # Consider using the attribute kroki-http-method with the value 'adaptive'.
            @http_client.get(uri, encoding)
          else
            @http_client.post("#{server_url}/#{type}/#{format}", text, encoding)
          end
        else
          @http_client.get(uri, encoding)
        end
      else
        @http_client.post("#{server_url}/#{type}/#{format}", text, encoding)
      end
    end

    def get_server_url
      @doc.attr('kroki-server-url', 'https://kroki.io')
    end
  end
end

=begin
.exports.save = function (krokiDiagram, doc, target, vfs, krokiClient) {
  const exists = typeof vfs != = 'undefined' && typeof vfs.exists === 'function' ? vfs.exists : require('./node-fs.js').exists
  const read = typeof vfs != = 'undefined' && typeof vfs.read === 'function' ? vfs.read : require('./node-fs.js').read
  const add = typeof vfs != = 'undefined' && typeof vfs.add === 'function' ? vfs.add : require('./node-fs.js').add

  const dirPath = getDirPath(doc)
  const diagramUrl = krokiDiagram.getDiagramUri(krokiClient.getServerUrl())
  const format = krokiDiagram.format
  const diagramName = `diag-${rusha.createHash().update(diagramUrl).digest('hex')}.${format}`
  const filePath = path.format({ dir: dirPath, base: diagramName })
  let encoding
  let mediaType
  if (format === 'txt' || format === 'atxt' || format === 'utxt')
    {
        mediaType = 'text/plain; charset=utf-8'
    encoding = 'utf8'
    }
  else
    if (format === 'svg')
      {
          mediaType = 'image/svg+xml'
      encoding = 'binary'
      }
    else
      {
          mediaType = 'image/png'
      encoding = 'binary'
      }
      // file is either (already) on the file system or we should read it from Kroki
      const contents = exists(filePath) ? read(filePath, encoding) : krokiClient.getImage(krokiDiagram, encoding)
      add({
              relative: dirPath,
              basename: diagramName,
              mediaType: mediaType,
              contents: Buffer.from(contents, encoding)
          })
      return diagramName
      }
=end
