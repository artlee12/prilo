package main

import (
	"bytes"
	"encoding/binary"
	"fmt"
	"image"
	"image/png"
	"math/bits"
)

const (
	maxClipboardImageBytes = 6 << 20
	maxClipboardImageDim   = 8192
	// 16M pixels covers a 5K screenshot and keeps decode plus DIB memory near 128 MB.
	maxClipboardImagePixels = 16 << 20
)

func pngToDIB(pngData []byte) ([]byte, error) {
	// Check the header first: a small PNG can declare dimensions that need gigabytes to decode.
	cfg, err := png.DecodeConfig(bytes.NewReader(pngData))
	if err != nil {
		return nil, fmt.Errorf("decode png header: %w", err)
	}
	if cfg.Width <= 0 || cfg.Height <= 0 || cfg.Width > maxClipboardImageDim || cfg.Height > maxClipboardImageDim ||
		int64(cfg.Width)*int64(cfg.Height) > maxClipboardImagePixels {
		return nil, fmt.Errorf("unsupported image dimensions %dx%d", cfg.Width, cfg.Height)
	}
	img, err := png.Decode(bytes.NewReader(pngData))
	if err != nil {
		return nil, fmt.Errorf("decode png: %w", err)
	}
	bounds := img.Bounds()
	w, h := bounds.Dx(), bounds.Dy()
	if w <= 0 || h <= 0 || w > maxClipboardImageDim || h > maxClipboardImageDim {
		return nil, fmt.Errorf("unsupported image dimensions %dx%d", w, h)
	}
	pixelBytes := int64(w) * int64(h) * 4
	if pixelBytes > 128<<20 {
		return nil, fmt.Errorf("image buffer too large")
	}

	dib := make([]byte, 40+int(pixelBytes))
	binary.LittleEndian.PutUint32(dib[0:4], 40)
	binary.LittleEndian.PutUint32(dib[4:8], uint32(w))
	binary.LittleEndian.PutUint32(dib[8:12], uint32(h))
	binary.LittleEndian.PutUint16(dib[12:14], 1)
	binary.LittleEndian.PutUint16(dib[14:16], 32)
	binary.LittleEndian.PutUint32(dib[16:20], 0)
	binary.LittleEndian.PutUint32(dib[20:24], uint32(pixelBytes))

	stride := w * 4
	for y := 0; y < h; y++ {
		dstRow := 40 + (h-1-y)*stride
		srcY := bounds.Min.Y + y
		for x := 0; x < w; x++ {
			r16, g16, b16, a16 := img.At(bounds.Min.X+x, srcY).RGBA()
			// Composite premultiplied RGBA over white so CF_DIB stays clean in opaque Windows apps.
			bg := 0xffff - a16
			off := dstRow + x*4
			dib[off+0] = uint8((b16 + bg) >> 8)
			dib[off+1] = uint8((g16 + bg) >> 8)
			dib[off+2] = uint8((r16 + bg) >> 8)
			dib[off+3] = 255
		}
	}
	return dib, nil
}

func extractMaskChannel(pixel, mask uint32) uint8 {
	if mask == 0 {
		return 0
	}
	shift := bits.TrailingZeros32(mask)
	width := bits.OnesCount32(mask >> shift)
	if width == 0 {
		return 0
	}
	val := (pixel & mask) >> shift
	if width >= 8 {
		return uint8(val >> (width - 8))
	}
	maxVal := uint32((1 << width) - 1)
	return uint8((val*255 + maxVal/2) / maxVal)
}

func dibToPNG(dib []byte) ([]byte, error) {
	if len(dib) < 40 {
		return nil, fmt.Errorf("dib too small")
	}
	biSize := binary.LittleEndian.Uint32(dib[0:4])
	if biSize < 40 || int(biSize) > len(dib) {
		return nil, fmt.Errorf("invalid dib header size %d", biSize)
	}
	w := int(int32(binary.LittleEndian.Uint32(dib[4:8])))
	rawH := int(int32(binary.LittleEndian.Uint32(dib[8:12])))
	topDown := rawH < 0
	h := rawH
	if topDown {
		h = -h
	}
	if w <= 0 || h <= 0 || w > maxClipboardImageDim || h > maxClipboardImageDim {
		return nil, fmt.Errorf("unsupported dib dimensions %dx%d", w, h)
	}
	planes := binary.LittleEndian.Uint16(dib[12:14])
	bpp := binary.LittleEndian.Uint16(dib[14:16])
	comp := binary.LittleEndian.Uint32(dib[16:20])
	if planes != 1 || (bpp != 24 && bpp != 32) {
		return nil, fmt.Errorf("unsupported dib format planes=%d bpp=%d", planes, bpp)
	}
	if comp != 0 && !(comp == 3 && bpp == 32) {
		return nil, fmt.Errorf("unsupported dib compression %d", comp)
	}

	pixelOffset := int(biSize)
	rMask := uint32(0x00ff0000)
	gMask := uint32(0x0000ff00)
	bMask := uint32(0x000000ff)
	aMask := uint32(0xff000000)
	if comp == 3 {
		if biSize == 40 {
			if len(dib) < 52 {
				return nil, fmt.Errorf("dib missing bitfields")
			}
			rMask = binary.LittleEndian.Uint32(dib[40:44])
			gMask = binary.LittleEndian.Uint32(dib[44:48])
			bMask = binary.LittleEndian.Uint32(dib[48:52])
			aMask = 0
			pixelOffset = 52
		} else {
			if len(dib) < 52 {
				return nil, fmt.Errorf("dib missing bitfields")
			}
			rMask = binary.LittleEndian.Uint32(dib[40:44])
			gMask = binary.LittleEndian.Uint32(dib[44:48])
			bMask = binary.LittleEndian.Uint32(dib[48:52])
			if biSize >= 56 && len(dib) >= 56 {
				aMask = binary.LittleEndian.Uint32(dib[52:56])
			} else {
				aMask = 0
			}
		}
	}

	var stride int
	if bpp == 24 {
		stride = ((w*3 + 3) / 4) * 4
	} else {
		stride = w * 4
	}
	if int64(pixelOffset)+int64(stride)*int64(h) > int64(len(dib)) {
		return nil, fmt.Errorf("dib pixel buffer truncated")
	}

	out := image.NewNRGBA(image.Rect(0, 0, w, h))
	anyAlphaNonZero := bpp == 24
	for y := 0; y < h; y++ {
		srcY := h - 1 - y
		if topDown {
			srcY = y
		}
		srcRow := pixelOffset + srcY*stride
		dstRow := y * out.Stride
		for x := 0; x < w; x++ {
			dst := dstRow + x*4
			if bpp == 24 {
				src := srcRow + x*3
				out.Pix[dst+0] = dib[src+2]
				out.Pix[dst+1] = dib[src+1]
				out.Pix[dst+2] = dib[src+0]
				out.Pix[dst+3] = 255
			} else {
				src := srcRow + x*4
				pixel := binary.LittleEndian.Uint32(dib[src : src+4])
				var a uint8
				if aMask != 0 {
					a = extractMaskChannel(pixel, aMask)
				}
				if a != 0 {
					anyAlphaNonZero = true
				}
				out.Pix[dst+0] = extractMaskChannel(pixel, rMask)
				out.Pix[dst+1] = extractMaskChannel(pixel, gMask)
				out.Pix[dst+2] = extractMaskChannel(pixel, bMask)
				out.Pix[dst+3] = a
			}
		}
	}

	if !anyAlphaNonZero {
		for y := 0; y < h; y++ {
			dstRow := y * out.Stride
			for x := 0; x < w; x++ {
				out.Pix[dstRow+x*4+3] = 255
			}
		}
	}

	var buf bytes.Buffer
	if err := png.Encode(&buf, out); err != nil {
		return nil, fmt.Errorf("encode png: %w", err)
	}
	if buf.Len() > maxClipboardImageBytes {
		return nil, fmt.Errorf("encoded png exceeds limit")
	}
	return buf.Bytes(), nil
}
