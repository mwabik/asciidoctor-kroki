# frozen_string_literal: true

require 'asciidoctor'
require_relative '../lib/asciidoctor/extensions/asciidoctor_kroki'

describe ::AsciidoctorExtensions::KrokiBlockProcessor do
  context 'convert to html5' do
    it 'should convert a PlantUML block to an image' do
      input = <<~'ADOC'
        [plantuml]
        ....
        alice -> bob: hello
        ....
      ADOC
      output = Asciidoctor.convert(input, standalone: false)
      (expect output).to eql %(<div class="imageblock kroki">
<div class="content">
<img src="https://kroki.io/plantuml/svg/eNpLzMlMTlXQtVNIyk-yUshIzcnJBwA9iwZL" alt="Diagram">
</div>
</div>)
    end
    it 'should use png if env-idea is defined' do
      input = <<~'ADOC'
        [plantuml]
        ....
        alice -> bob: hello
        ....
      ADOC
      output = Asciidoctor.convert(input, attributes: { 'env-idea' => '' }, standalone: false)
      (expect output).to eql %(<div class="imageblock kroki">
<div class="content">
<img src="https://kroki.io/plantuml/png/eNpLzMlMTlXQtVNIyk-yUshIzcnJBwA9iwZL" alt="Diagram">
</div>
</div>)
    end
    it 'should convert a diagram with a relative path to an image' do
      input = <<~'ADOC'
        :imagesdir: .asciidoctor/kroki

        plantuml::spec/fixtures/alice.puml[svg,role=sequence]
      ADOC
      output = Asciidoctor.convert(input, attributes: { 'kroki-fetch-diagram' => '' }, standalone: false)
      (expect output).to eql %(<div class="imageblock sequence kroki-format-svg kroki">
<div class="content">
<img src="https://kroki.io/plantuml/svg/eNpLzMlMTlXQtVNIyk-yUshIzcnJ5wIAQ-AGVQ==" alt="Diagram">
</div>
</div>)
    end
  end
end
