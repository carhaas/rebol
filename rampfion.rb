#!/usr/bin/env ruby

require 'nlp_ruby'
require 'trollop'
require 'tempfile'
require 'memcached'
require_relative './hopefear'


SMT_SEMPARSE = 'python /workspace/grounded/smt-semparse-cp/decode_sentence.py /workspace/grounded/smt-semparse-cp/working/full_dataset 2>/dev/null'
EVAL_PL = '/workspace/grounded/wasp-1.0/data/geo-funql/eval/eval.pl'
$cache = Memcached.new("localhost:11211")

def exec natural_language_string, reference_output, no_output=false
  func = nil
  output = nil
  feedback = nil
  key_prefix = natural_language_string.encode("ASCII", :invalid => :replace, :undef => :replace, :replace => "?").gsub(/ /,'_')
  begin
    func = $cache.get key_prefix+"__FUNC"
    output = $cache.get key_prefix+"__OUTPUT"
    feedback = $cache.get key_prefix+"__FEEDBACK"
  rescue Memcached::NotFound
    #func   = spawn_with_timeout("#{SMT_SEMPARSE} \"#{natural_language_string}\"").strip
    func   = `#{SMT_SEMPARSE} "#{natural_language_string}"`.strip
    #output = spawn_with_timeout("echo \"execute_funql_query(#{func}, X).\" | swipl -s #{EVAL_PL} 2>&1  | grep \"X =\"").strip.split('X = ')[1]
    output = `echo "execute_funql_query(#{func}, X)." | swipl -s #{EVAL_PL} 2>&1  | grep "X ="`.strip.split('X = ')[1]
    feedback = output==reference_output
    begin
      $cache.set key_prefix+"__FUNC", func
      $cache.set key_prefix+"__OUTPUT", output
      $cache.set key_prefix+"__FEEDBACK", feedback
    rescue SystemExit, Interrupt
      $cache.delete key_prefix+"__FUNC"
      $cache.delete key_prefix+"__OUTPUT"
      $cache.delete key_prefix+"__FEEDBACK"
    end
  end
  STDERR.write "        nrl: #{natural_language_string}\n" if !no_output
  STDERR.write "        mrl: #{func}\n" if !no_output
  STDERR.write "     output: #{output}\n" if !no_output
  STDERR.write "   correct?: #{feedback}\n" if !no_output
  return feedback, func, output
end

class Stats

  def initialize name
    @name = name
    @with_parse = 0.0
    @with_output = 0.0
    @with_correct_output = 0.0
  end

  # FIXME
  def update feedback, func, output
    @with_parse +=1 if func!='None'&&func!=''
    @with_output +=1 if output!='null'&&output!=''
    @with_correct_output += 1 if feedback==true
  end

  def to_s total
    without_parse = total-@with_parse
<<-eos
         #{@name} with parse #{((@with_parse/total)*100).round 2}% abs=#{@with_parse}
        #{@name} with output #{((@with_output/total)*100).round 2}% abs=#{@with_output}
#{@name} with correct output #{((@with_correct_output/total)*100).round 2}% adj=#{((@with_correct_output/(total-without_parse))*100).round 2} abs=#{@with_correct_output}
eos
  end
end

# map model scores to lie within [0,1]
def adjust_model_scores kbest, factor
  min = kbest.map{ |k| k.score }.min
  max = kbest.map{ |k| k.score }.max
  kbest.each { |k| k.score = factor*((k.score-min)/(max-min)) }
end

def update model, hope, fear, eta
  diff = hope.f - fear.f
  diff *= eta
  model += diff
  return model
end

def main
  cfg = Trollop::options do
    # data
    opt :k,             "k",                      :type => :int,    :default => 10000, :short => '-k'
    opt :input,         "'foreign' input",        :type => :string, :required => true, :short => '-i'
    opt :references,    "(parseable) references", :type => :string, :required => true, :short => '-r'
    opt :gold,          "gold output",            :type => :string, :required => true, :short => '-g'
    opt :gold_mrl,      "gold parse",             :type => :string, :required => true, :short => '-h'
    opt :init_weights,  "initial weights",        :type => :string, :required => true, :short => '-w'
    opt :cdec_ini,      "cdec config file",       :type => :string, :required => true, :short => '-c'
    # output
    opt :output_weights, "output file for final weights", :type => :string, :required => true, :short => '-o'
    opt :debug,          "debug output",                  :type => :bool,   :default => false, :short => '-d'
    opt :print_kbest,    "print full kbest lists",        :type => :bool,   :default => false, :short => '-l'
    # learning parameters
    opt :eta,                    "learning rate",                                              :type => :float, :default => 0.01,  :short => '-e'
    opt :iterate,                "iteration X epochs",                                         :type => :int,   :default => 1,     :short => '-j'
    opt :stop_after,             "stop after x examples",                                      :type => :int,   :default => -1,    :short => '-s'
    opt :scale_model,            "scale model scores by this factor",                          :type => :float, :default => 1.0,   :short => '-m'
    opt :normalize,              "normalize weights after each update",                        :type => :bool,  :default => false, :short => '-n'
    opt :skip_on_no_proper_gold, "skip, if the reference didn't produce a proper gold output", :type => :bool,  :default => false, :short => '-x'
    opt :no_update,              "don't update weights",                                       :type => :bool,  :default => false, :short => '-y'
    opt :hope_fear_max,          "FIXME",                                                      :type => :int,   :default => 32,    :short => '-q'
    opt :variant, "standard, rampion, fear_no_exec, fear_no_exec_skip, fear_no_exec_hope_exec, fear_no_exec_hope_exec_skip, only_exec", :default => 'standard', :short => '-v'
  end

  STDERR.write "CONFIGURATION\n"
  cfg.each_pair { |k,v| STDERR.write " #{k}=#{v}\n" }

  input      = ReadFile.new(cfg[:input]).readlines_strip
  references = ReadFile.new(cfg[:references]).readlines_strip
  gold       = ReadFile.new(cfg[:gold]).readlines_strip
  gold_mrl   = ReadFile.new(cfg[:gold_mrl]).readlines_strip # FIXME => prolog!
  stopwords  = ReadFile.new('prototype/d/stopwords.en').readlines_strip

  own_references = nil
  own_references = references.map{ |i| nil } if cfg[:variant]=='only_exec'

  w = SparseVector.new
  w.from_kv_file cfg[:init_weights]
  last_weights_fn = ''

  cfg[:iterate].times { |iter|

    # numerous counters
    count                 = 0
    without_translation   = 0
    no_proper_gold_output = 0
    top1_stats = Stats.new 'top1'
    hope_stats = Stats.new 'hope'
    fear_stats = Stats.new 'fear'
    refs_stats = Stats.new 'refs'
    type1_updates     = 0
    type2_updates     = 0
    top1_hit          = 0
    top1_variant      = 0
    top1_true_variant = 0
    hope_hit          = 0
    hope_variant      = 0
    hope_true_variant = 0
    kbest_sz          = 0

    input.each_with_index { |i,j|
      count += 1

      tmp_file        = Tempfile.new('rampion')
      tmp_file_path   = tmp_file.path
      last_weights_fn = tmp_file.path
      tmp_file.write w.to_kv ' '
      tmp_file.close

      kbest = CDEC::kbest i, cfg[:cdec_ini], tmp_file_path, cfg[:k]
      kbest_sz += kbest.size

      STDERR.write "\n=================\n"
      STDERR.write "    EXAMPLE: #{j}\n"
      STDERR.write "   GOLD MRL: #{gold_mrl[j]}\n"
      STDERR.write "GOLD OUTPUT: #{gold[j]}\n"

      if kbest.size == 0
        without_translation += 1
        STDERR.write "NO MT OUTPUT, skipping example\n"
        next
      end

      if gold[j] == '[]' || gold[j] == '[...]' || gold[j] == '[].'
        no_proper_gold_output += 1
        if cfg[:skip_on_no_proper_gold]
          STDERR.write "NO PROPER GOLD OUTPUT, skipping example\n"
          next
        end
      end

      kbest.each { |k| k.other_score = BLEU::per_sentence_bleu k.s, references[j] }

      if cfg[:print_kbest]
        STDERR.write "\n<<< KBEST\n"
        kbest.each_with_index { |k,l| STDERR.write k.to_s+"\n" }
        STDERR.write ">>>\n"
      end

      adjust_model_scores kbest, cfg[:scale_model]

      STDERR.write "\n [TOP1]\n"
      STDERR.write "#{kbest[0].s}\n"
      puts "#{kbest[0].s}" if iter+1==cfg[:iterate]

      feedback, func, output = exec kbest[0].s, gold[j]
      top1_stats.update feedback, func, output


      hope = fear = new_reference = nil
      type1 = type2 = skip = false
      case cfg[:variant]
      when 'standard'
        hope, fear, skip, type1, type2 = gethopefear_standard kbest, feedback
      when 'rampion'
        hope, fear, skip, type1, type2 = gethopefear_rampion kbest, references[j]
      when 'fear_no_exec_skip'
        hope, fear, skip, type1, type2 = gethopefear_fear_no_exec_skip kbest, feedback, gold[j]
      when 'fear_no_exec'
        hope, fear, skip, type1, type2 = gethopefear_fear_no_exec kbest, feedback, gold[j], cfg[:hope_fear_max]
      when 'fear_no_exec_hope_exec'
        hope, fear, skip, type1, type2 = gethopefear_fear_no_exec_hope_exec kbest, feedback, gold[j], cfg[:hope_fear_max]
      when 'fear_no_exec_hope_exec_skip'
        hope, fear, skip, type1, type2 = gethopefear_fear_no_exec_hope_exec_skip kbest, feedback, gold[j], cfg[:hope_fear_max]
      when 'only_exec'
        hope, fear, skip, type1, type2, new_reference = gethopefear_only_exec kbest, feedback, gold[j], cfg[:hope_fear_max], own_references[j]
      else
        STDERR.write "NO SUCH VARIANT, exiting.\n"
        exit 1
      end

      if new_reference
        own_references[j] = new_reference
      end

      type1_updates+=1 if type1
      type2_updates+=1 if type2

      ref_words = bag_of_words references[j], stopwords

      if kbest[0].s == references[j]
        top1_hit += 1
      else
        top1_variant += 1
        top1_true_variant += 1 if !bag_of_words(kbest[0].s, stopwords).is_subset_of?(ref_words)
      end
      if hope && hope.s==references[j]
        hope_hit += 1
      elsif hope
        hope_variant += 1
        hope_true_variant += 1 if !bag_of_words(hope.s, stopwords).is_subset_of?(ref_words)
      end

      STDERR.write "\n [HOPE]\n"
      if hope
        feedback, func, output =  exec hope.s, gold[j]
        hope_stats.update feedback, func, output
      end
      STDERR.write "\n [FEAR]\n"
      if fear
        feedback, func, output = exec fear.s, gold[j]
        fear_stats.update  feedback, func, output
      end
      STDERR.write "\n [REFERENCE]\n"
      feedback, func, output = exec references[j], gold[j]
      refs_stats.update feedback, func, output

      if skip || !hope || !fear
        STDERR.write "NO GOOD HOPE/FEAR, skipping example\n\n"
        next
      end

      w = update w, hope, fear, cfg[:eta] if !cfg[:no_update]
      w.normalize! if cfg[:normalize]

      break if cfg[:stop_after]>0&&(j+1)==cfg[:stop_after]
    }

    if cfg[:iterate] > 1
      WriteFile.new("#{cfg[:output_weights]}.#{iter}.gz").write(ReadFile.new(last_weights_fn).read)
    else
      FileUtils::cp(last_weights_fn, cfg[:output_weights])
    end

    STDERR.write  <<-eos

---
  iteration ##{iter+1}/#{cfg[:iterate]}: #{count} examples
        type1 updates: #{type1_updates}
        type2 updates: #{type2_updates}
            top1 hits: #{top1_hit}
         top1 variant: #{top1_variant}
    top1 true variant: #{top1_true_variant}
            hope hits: #{hope_hit}
         hope variant: #{hope_variant}
    hope true variant: #{hope_true_variant}
           kbest size: #{(kbest_sz/count).round 2}
    #{((without_translation.to_f/count)*100).round 2}% without translations (abs: #{without_translation})
    #{((no_proper_gold_output.to_f/count)*100).round 2}% no good gold output (abs: #{no_proper_gold_output})

#{top1_stats.to_s count}
#{hope_stats.to_s count}
#{fear_stats.to_s count}
#{refs_stats.to_s count}

eos

  }
end


main
