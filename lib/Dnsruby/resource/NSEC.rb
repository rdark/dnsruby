#--
#Copyright 2007 Nominet UK
#
#Licensed under the Apache License, Version 2.0 (the "License");
#you may not use this file except in compliance with the License. 
#You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0 
#
#Unless required by applicable law or agreed to in writing, software 
#distributed under the License is distributed on an "AS IS" BASIS, 
#WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied. 
#See the License for the specific language governing permissions and 
#limitations under the License.
#++
module Dnsruby
  class RR
    #RFC4034, section 4
    #The NSEC resource record lists two separate things: the next owner
    #name (in the canonical ordering of the zone) that contains
    #authoritative data or a delegation point NS RRset, and the set of RR
    #types present at the NSEC RR's owner name [RFC3845].  The complete
    #set of NSEC RRs in a zone indicates which authoritative RRsets exist
    #in a zone and also form a chain of authoritative owner names in the
    #zone.  This information is used to provide authenticated denial of
    #existence for DNS data, as described in [RFC4035].    
    class NSEC < RR
      ClassValue = nil #:nodoc: all
      TypeValue = Types::NSEC #:nodoc: all
      
      #The next name which exists after this NSEC
      #The Next Domain field contains the next owner name (in the canonical
      #ordering of the zone) that has authoritative data or contains a
      #delegation point NS RRset
      attr_reader :next_domain
      #The Type Bit Maps field identifies the RRset types that exist at the
      #NSEC RR's owner name
      attr_reader :types
      
      def next_domain=(n)
        nxt = Name.create(n)
        @next_domain = nxt
      end
      
      def types=(t)
        @types = NSEC.get_types(t)
      end
      
      def self.get_types(t)
        types = nil
        if (t.instance_of?Array)
          # from the wire, already decoded
          types =t
        elsif (t.instance_of?String)
          # List of mnemonics
          types=[]
          mnemonics = t.split(" ")
          mnemonics.pop
          mnemonics.each do |m|
            type = Types.new(m)
            types.push(type)
          end
        else
          raise DecodeError.new("Unknown format of types for Dnsruby::RR::NSEC")
        end
        return types
      end
      
      def add_type(t)
        self.types=(@types + [t])
      end
      
      def self.decode_types(bytes)
        types = []
        #RFC4034 section 4.1.2
        #The RR type space is split into 256 window blocks, each representing
        #the low-order 8 bits of the 16-bit RR type space.  Each block that
        #has at least one active RR type is encoded using a single octet
        #window number (from 0 to 255), a single octet bitmap length (from 1
        #to 32) indicating the number of octets used for the window block's
        #bitmap, and up to 32 octets (256 bits) of bitmap.

        #Blocks are present in the NSEC RR RDATA in increasing numerical
        #order.

        #  Type Bit Maps Field = ( Window Block # | Bitmap Length | Bitmap )+

        #  where "|" denotes concatenation.
       
        pos = 0
        while (pos < bytes.length)
          #So, read the first two octets
          if (bytes.length-pos < 2)
            raise DecodeError.new("NSEC : Expected window number and bitmap length octets")
          end
          window_number = bytes[pos]
          bitmap_length = bytes[pos+1]
          pos += 2
          bitmap = bytes[pos,bitmap_length]
          pos += bitmap_length
          #Each bitmap encodes the low-order 8 bits of RR types within the
          #window block, in network bit order.  The first bit is bit 0.  For
          #window block 0, bit 1 corresponds to RR type 1 (A), bit 2 corresponds
          #to RR type 2 (NS), and so forth.  For window block 1, bit 1
          #corresponds to RR type 257, and bit 2 to RR type 258.  If a bit is
          #set, it indicates that an RRset of that type is present for the NSEC
          #RR's owner name.  If a bit is clear, it indicates that no RRset of
          #that type is present for the NSEC RR's owner name.
          index = 0
          bitmap.each_byte do |char|
            if char.to_i != 0
              # decode these RR types
              0..8.times do |i|
                if (((1 << (7-i)) & char) == (1 << (7-i)))
                  type = Types.new((256 * window_number) + (8 * index) + i)
                  #Bits representing pseudo-types MUST be clear, as they do not appear
                  #in zone data.  If encountered, they MUST be ignored upon being read.
                  if (!([Types.OPT, Types.TSIG].include?(type)))
                    types.push(type)
                  end
                end               
              end
            end
            index += 1
          end
        end
        return types
      end
      
      def encode_types
        NSEC.encode_types(self)
      end
      
      def self.encode_types(nsec)
        output=""
        #types represents all 65536 possible RR types.
        #Split up types into sets of 256 different types.
        type_codes = []
        nsec.types.each do |type|
          type_codes.push(type.code)
        end
        type_codes.sort!
        window = -1
        0.step(65536,256) { |step|
          # Gather up the RR types for this set of 256
          types_to_go = []
          while (type_codes[0] < step)
            types_to_go.push(type_codes[0])
            # And delete them from type_codes
            type_codes=type_codes.last(type_codes.length-1)
            break if (type_codes.empty?)
          end
          
          if (!types_to_go.empty?)
            # Then create the bitmap for them
            bitmap=""
            # keep on adding them until there's none left
            pos = 0
            bitmap_pos = 0
            while (!types_to_go.empty?)
              
              # Check the next eight
              byte = 0
              pos += 8
              while (types_to_go[0] < pos + step-256)
                byte = byte | (1 << (pos-1-(types_to_go[0] - (step-256) )))
                # Add it to the list
                # And remove it from the to_go queue
                types_to_go =types_to_go.last(types_to_go.length-1)
                break if (types_to_go.empty?)
              end
              bitmap += " "
              bitmap[bitmap_pos]=byte
              bitmap_pos+=1
            end
            
            # Now add data to output bytes
            start = output.length
            (2+bitmap.length).times do 
              output += " "
            end
          
            output[start] = window
            output[start+1] = bitmap.length
            bitmap.length.times do |i|
              output[start+2+i] = bitmap[i]
            end
          end
          window += 1
          
          # Are there any more types after this?
          if (type_codes.empty?)
            # If not, then break (so we don't add more zeros)
            break
          end
        }
        return output
      end

      def from_data(data) #:nodoc: all
        next_domain, types = data
        self.next_domain=(next_domain)
        self.types=(types)
      end
      
      def from_string(input)
        if (input.length > 0)
          data = input.split(" ")
          self.next_domain=(data[0])
          len = data[0].length + data[1].length + 1
          self.types=(input[len, input.length-len])
        end
      end
      
      def rdata_to_string #:nodoc: all
        if (@next_domain!=nil)
          type_strings = []
          @types.each do |t|
            type_strings.push(t.string)
          end
          types = type_strings.join(" ")
          return "#{@next_domain} ( #{types} )"
        else
          return ""
        end
      end
      
      def encode_rdata(msg, canonical=false) #:nodoc: all
        # Canonical
        msg.put_name(@next_domain, true)
        types = encode_types
        msg.put_bytes(types)
      end
      
      def self.decode_rdata(msg) #:nodoc: all
        next_domain = msg.get_name
        types = decode_types(msg.get_bytes)
        return self.new(
          [next_domain, types])
      end
    end 
  end
end