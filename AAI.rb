#!/usr/bin/env ruby

#
# @author: Luis M. Rodriguez-R
# @update: Oct-28-2013
# @license: artistic license 2.0
#

require 'optparse'
require 'tmpdir'
has_rest_client = TRUE
begin
   require 'rubygems'
   require 'restclient'
rescue LoadError
   has_rest_client = FALSE
end

o = {:len=>0, :id=>20, :bits=>0, :hits=>50, :q=>FALSE, :bin=>'', :program=>'blast+', :thr=>1}
OptionParser.new do |opts|
   opts.banner = "
Calculates the Average Amino acid Identity between two genomes.

Usage: #{$0} [options]"
   opts.separator ""
   opts.separator "Mandatory"
   opts.on("-1", "--seq1 FILE", "Path to the FastA file containing the genome 1 (proteins)."){ |v| o[:seq1] = v }
   opts.on("-2", "--seq2 FILE", "Path to the FastA file containing the genome 2 (proteins)."){ |v| o[:seq2] = v }
   if has_rest_client
      opts.separator "    Alternatively, you can supply the GI of a genome (nucleotides) with the format gi:12345 instead of files."
   else
      opts.separator "    Install rest-client to enable gi support."
   end
   opts.separator ""
   opts.separator "Search Options"
   opts.on("-l", "--len INT", "Minimum alignment length (in aa).  By default: #{o[:len].to_s}."){ |v| o[:len] = v.to_i }
   opts.on("-i", "--id NUM", "Minimum alignment identity (in %).  By default: #{o[:id].to_s}."){ |v| o[:id] = v.to_f }
   opts.on("-s", "--bitscore NUM", "Minimum bit score (in bits).  By default: #{o[:bits].to_s}."){ |v| o[:bits] = v.to_f }
   opts.on("-n", "--hits INT", "Minimum number of hits.  By default: #{o[:hits].to_s}."){ |v| o[:hits] = v.to_i }
   opts.separator ""
   opts.separator "Software Options"
   opts.on("-b", "--bin DIR", "Path to the directory containing the binaries of the search program."){ |v| o[:bin] = v }
   opts.on("-p", "--program STR", "Search program to be used.  One of: blast+ (default), blast, blat."){ |v| o[:program] = v }
   opts.on("-t", "--threads INT", "Number of parallel threads to be used.  By default: #{o[:thr]}."){ |v| o[:thr] = v.to_i }
   opts.separator ""
   opts.separator "Other Options"
   opts.on("-o", "--out FILE", "Saves a file describing the alignments used for two-way ANI."){ |v| o[:out] = v }
   opts.on("-r", "--res FILE", "Saves a file with the final results."){ |v| o[:res] = v }
   opts.on("-q", "--quiet", "Run quietly (no STDERR output)"){ o[:q] = TRUE }
   opts.on("-h", "--help", "Display this screen") do
      puts opts
      exit
   end
   opts.separator ""
end.parse!
abort "-1 is mandatory" if o[:seq1].nil?
abort "-2 is mandatory" if o[:seq2].nil?
o[:bin] = o[:bin]+"/" if o[:bin].size > 0

Dir.mktmpdir do |dir|
   $stderr.puts "Temporal directory: #{dir}." unless o[:q]

   # Create databases.
   $stderr.puts "Creating databases." unless o[:q]
   [:seq1, :seq2].each do |seq|
      gi = /^gi:(\d+)/.match(o[seq])
      if not gi.nil?
	 abort "GI requested but rest-client not supported.  First install gem rest-client." unless has_rest_client
	 $stderr.puts "  Downloading dataset from GI:#{gi[1]}." unless o[:q]
	 responseLink = RestClient.get 'http://eutils.ncbi.nlm.nih.gov/entrez/eutils/elink.fcgi', {:params=>{:db=>'protein',:dbfrom=>'nuccore', :id=>gi[1]}}
	 abort "Unable to reach NCBI EUtils, error code #{responseLink.code}." unless responseLink.code == 200
	 fromId = TRUE
	 protIds = []
	 o[seq] = "#{dir}/gi-#{seq.to_s}.fa"
	 fo = File.open(o[seq], "w")
	 responseLink.to_str.each_line.grep(/<Id>/) do |ln|
	    idMatch = /<Id>(\d+)<\/Id>/.match(ln);
	    unless idMatch.nil?
	       protIds.push(idMatch[1]) unless fromId
	       fromId = FALSE
	    end
	 end
	 response = RestClient.post 'http://eutils.ncbi.nlm.nih.gov/entrez/eutils/efetch.fcgi', :db=>'nuccore', :rettype=>'fasta', :id=>protIds.join(',')
	 abort "Unable to reach NCBI EUtils, error code #{response.code}." unless response.code == 200
	 fo.puts response.to_str
	 fo.close
      end
      $stderr.puts "  Reading FastA file: #{o[seq]}" unless o[:q]
      seqs = 0
      fi = File.open(o[seq], "r")
      fo = File.open("#{dir}/#{seq.to_s}.fa", "w")
      fi.each_line do |ln|
	 if /^>(\S+)/.match(ln).nil?
	    fo.puts ln
	 else
	    seqs += 1
	    fo.puts ">#{seqs}"
	 end
      end
      fi.close
      fo.close
      $stderr.puts "    File contains #{seqs} sequences." unless o[:q]
      case o[:program].downcase
      when "blast"
         `"#{o[:bin]}formatdb" -i "#{dir}/#{seq.to_s}.fa" -p T`
      when "blast+"
         `"#{o[:bin]}makeblastdb" -in "#{dir}/#{seq.to_s}.fa" -dbtype prot`
      when "blat"
      	 # Nothing to do
      else
         abort "Unsupported program: #{o[:program]}."
      end
   end

   # Best-hits.
   $stderr.puts "Running one-way comparisons." unless o[:q]
   rbh = []
   id2 = 0
   sq2 = 0
   n2  = 0
   unless o[:out].nil?
      fo = File.open(o[:out], "w")
      fo.puts %w(identity aln.len mismatch gap.open evalue bitscore).join("\t")
   end
   res = File.open(o[:res], "w") unless o[:res].nil?
   [1,2].each do |i|
      q = "#{dir}/seq#{i}.fa"
      s = "#{dir}/seq#{i==1?2:1}.fa"
      case o[:program].downcase
      when "blast"
	 `"#{o[:bin]}blastall" -p blastp -d "#{s}" -i "#{q}" \
	 -v 1 -b 1 -a #{o[:thr]} -m 8 -o "#{dir}/#{i}.tab"`
	 #-F F -e 0.001 -v 1 -b 1 -X 150 -a #{o[:thr]} -m 8 -o "#{dir}/#{i}.tab"`
      when "blast+"
	 `"#{o[:bin]}blastp" -db "#{s}" -query "#{q}" \
	 -max_target_seqs 1 \
	 -num_threads #{o[:thr]} -outfmt 6 -out "#{dir}/#{i}.tab"`
	 #-dust no -max_target_seqs 1 -xdrop_ungap 150 -xdrop_gap 150 \
      when "blat"
	 `#{o[:bin]}blat "#{s}" "#{q}" -prot -out=blast8 "#{dir}/#{i}.tab.unsorted"`
	 `sort -k 1 "#{dir}/#{i}.tab.unsorted" > "#{dir}/#{i}.tab"`
      else
	 abort "Unsupported program: #{o[:program]}."
      end
      fh = File.open("#{dir}/#{i}.tab", "r")
      id = 0
      sq = 0
      n  = 0
      last_ID = ""
      fh.each_line do |ln|
	 ln.chomp!
	 row = ln.split(/\t/)
	 next if last_ID == row[0]
	 if row[3].to_i >= o[:len] and row[2].to_f >= o[:id] and row[11].to_f >= o[:bits]
	    id += row[2].to_f
	    sq += row[2].to_f ** 2
	    n  += 1
	    if i==1
	       rbh[ row[0].to_i ] = row[1].to_i
	    else
	       if !rbh[ row[1].to_i ].nil? and rbh[ row[1].to_i ]==row[0].to_i
	          id2 += row[2].to_f
		  sq2 += row[2].to_f**2
		  n2  += 1
		  fo.puts [row[2..5],row[10..11]].join("\t") unless o[:out].nil?
	       end
	    end
	 end
      end
      fh.close
      if n < o[:hits]
	 puts "Insuffient hits to estimate one-way AAI: #{n}."
	 res.puts "Insufficient hits to estimate one-way AAI: #{n}"
      else
	 printf "! One-way AAI %d: %.2f%% (SD: %.2f%%), from %i proteins.\n", i, id/n, (sq/n - (id/n)**2)**0.5, n
	 res.puts sprintf "<b>One-way AAI %d:</b> %.2f%% (SD: %.2f%%), from %i proteins.<br/>", i, id/n, (sq/n - (id/n)**2)**0.5, n unless o[:res].nil?
      end
   end
   if n2 < o[:hits]
      puts "Insufficient hits to estimate two-way AAI: #{n2}"
      res.puts "Insufficient hits to estimate two-way AAI: #{n2}"
   else
      printf "! Two-way AAI  : %.2f%% (SD: %.2f%%), from %i proteins.\n", id2/n2, (sq2/n2 - (id2/n2)**2)**0.5, n2
      res.puts sprintf "<b>Two-way AAI:</b> %.2f%% (SD: %.2f%%), from %i proteins.<br/>", id2/n2, (sq2/n2 - (id2/n2)**2)**0.5, n2 unless o[:res].nil?
   end
   fo.close unless o[:out].nil?
end

