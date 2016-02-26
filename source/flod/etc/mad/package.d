module flod.etc.mad;

import flod.traits;

struct MadDecoder(Source, Sink) {
	import deimos.mad;

	Source source;
	Sink sink;
	const(void)* bufferStart = null;
	Throwable exception;

	private extern(C)
	static mad_flow input(void* data, mad_stream* stream)
	{
		auto self = cast(MadDecoder*) data;
		try {
			if (self.bufferStart !is null) {
				size_t cons = stream.this_frame - self.bufferStart;
				if (cons == 0)
					return mad_flow.STOP;
				self.source.consume(cons);
			}
			auto buf = self.source.peek(4096);
			if (!buf.length)
				return mad_flow.STOP;
			self.bufferStart = buf.ptr;
			mad_stream_buffer(stream, buf.ptr, buf.length);
			return mad_flow.CONTINUE;
		}
		catch (Throwable e) {
			self.exception = e;
			return mad_flow.BREAK;
		}
	}

	private static int scale(mad_fixed_t sample)
	{
		/* round */
		sample += (1L << (MAD_F_FRACBITS - 16));

		/* clip */
		if (sample >= MAD_F_ONE)
			sample = MAD_F_ONE - 1;
		else if (sample < -MAD_F_ONE)
			sample = -MAD_F_ONE;

		/* quantize */
		return sample >> (MAD_F_FRACBITS + 1 - 16);
	}

	private extern(C)
	static mad_flow output(void* data, const(mad_header)* header, mad_pcm* pcm)
	{
		auto self = cast(MadDecoder*) data;
		uint nchannels, nsamples;
		const(mad_fixed_t)* left_ch;
		const(mad_fixed_t)* right_ch;

		nchannels = pcm.channels;
		nsamples  = pcm.length;
		left_ch   = pcm.samples[0].ptr;
		right_ch  = pcm.samples[1].ptr;

		if (nsamples > 0) {
			size_t size = short.sizeof * nchannels * nsamples;
			auto buf = new ubyte[size];
			//auto buf = self.sink.alloc(size);
			size_t i = 0;
			while (nsamples--) {
				int sample = scale(*left_ch++);
				buf[i++] = (sample >> 0) & 0xff;
				buf[i++] = (sample >> 8) & 0xff;
				if (nchannels == 2) {
					sample = scale(*right_ch++);
					buf[i++] = (sample >> 0) & 0xff;
					buf[i++] = (sample >> 8) & 0xff;
				}
			}
			self.sink.push(buf);
			//self.sink.commit(size);
		}
		return mad_flow.CONTINUE;
	}

	private extern(C)
	static mad_flow error(void* data, mad_stream* stream, mad_frame* frame)
	{
		return mad_flow.CONTINUE;
	}

	void run()
	{
		// TODO: why is this reference 0ed after mad_decoder_init?
		auto md = &this;
		mad_decoder decoder;
		mad_decoder_init(&decoder, cast(void*) md,
			&input, null /* header */, null /* filter */,
			&output, &error, null /* message */);

		/* start decoding */
		auto result = mad_decoder_run(&decoder, mad_decoder_mode.SYNC);

		/* release the decoder */
		mad_decoder_finish(&decoder);
		if (md.exception)
			throw md.exception;
	}
}
static assert(isPeekSink!MadDecoder);
static assert(isPushSource!MadDecoder);
