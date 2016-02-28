///
module flod.etc.mad;

import flod.pipeline;
import flod.traits : check;

///
auto decodeMp3(Pipeline)(auto ref Pipeline pipeline)
{
	return pipeline.pipe!MadDecoder;
}

private:

struct MadDecoder(Source, Sink) {
	import deimos.mad;
	static assert(mad_decoder.sizeof == 88);

	Source source;
	Sink sink;
	const(void)* bufferStart = null;
	size_t chunkSize = 4096;

	Throwable exception;

	private mad_flow input(mad_stream* stream)
	{
		import core.exception : OutOfMemoryError, InvalidMemoryOperationError;
		try {
			size_t cons;
			if (bufferStart !is null) {
				cons = stream.this_frame - bufferStart;
				if (cons > 0) {
					source.consume(cons);
					if (chunkSize > 4096)
						chunkSize = 4096;
				}
				switch (stream.error) with (mad_error) {
				case BUFLEN:
					if (cons == 0)
						chunkSize *= 2;
					break;
				case BUFPTR:
					throw new InvalidMemoryOperationError("MAD error: invalid buffer pointer");
				case NOMEM:
					throw new OutOfMemoryError("MAD error: out of memory");
				default:
					break;
				}
			}
			auto buf = source.peek(chunkSize);
			if (cons == 0 && buf.length < chunkSize)
				return mad_flow.STOP;
			bufferStart = buf.ptr;
			mad_stream_buffer(stream, buf.ptr, buf.length);
			return mad_flow.CONTINUE;
		}
		catch (Throwable e) {
			exception = e;
			return mad_flow.BREAK;
		}
	}

	private extern(C)
	static mad_flow inputCallback(void* data, mad_stream* stream)
	{
		auto self = cast(MadDecoder*) data;
		return self.input(stream);
	}

	private static int scale(mad_fixed_t sample) @nogc nothrow pure
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

	mad_flow output(const(mad_header)* header, mad_pcm* pcm)
	{
		try {
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
				//auto buf = sink.alloc(size);
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
				sink.push(buf);
				//sink.commit(size);
			}
		} catch (Throwable e) {
			exception = e;
			return mad_flow.BREAK;
		}
		return mad_flow.CONTINUE;
	}

	private extern(C)
	static mad_flow outputCallback(void* data, const(mad_header)* header, mad_pcm* pcm)
	{
		auto self = cast(MadDecoder*) data;
		return self.output(header, pcm);
	}

	private extern(C)
	static mad_flow errorCallback(void* data, mad_stream* stream, mad_frame* frame) @nogc nothrow
	{
		return mad_flow.CONTINUE;
	}

	void run()
	{
		mad_decoder decoder;
		mad_decoder_init(&decoder, cast(void*) &this,
			&inputCallback, null /* header */, null /* filter */,
			&outputCallback, &errorCallback, null /* message */);
		assert(&this !is null);

		/* start decoding */
		auto result = mad_decoder_run(&decoder, mad_decoder_mode.SYNC);

		/* release the decoder */
		mad_decoder_finish(&decoder);
		if (exception)
			throw exception;
	}
}

enum ch = check!("peek", "push", MadDecoder);
