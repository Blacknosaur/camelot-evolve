//! OWNER: vision agent. Pure kernels over RGBA/luma buffers for the Camelot web client, compiled to WASM and run
//! inside Web Workers. Each kernel mirrors a TypeScript implementation in
//! `apps/web/src/features/analysis/{tracking,field}`; JS keeps those as fallbacks, so the numerical behaviour here
//! must match them (same thresholds, same orderings).
use wasm_bindgen::prelude::*;

/// Sanity export used by the worker to confirm the module loaded.
#[wasm_bindgen]
pub fn version() -> String {
    env!("CARGO_PKG_VERSION").to_string()
}

/// Converts RGBA8 to a single-channel luma buffer (BT.601 weights).
#[wasm_bindgen]
pub fn rgba_to_luma(rgba: &[u8], width: u32, height: u32) -> Vec<u8> {
    let n = (width * height) as usize;
    let mut out = vec![0u8; n];
    for i in 0..n.min(rgba.len() / 4) {
        let r = rgba[i * 4] as u32;
        let g = rgba[i * 4 + 1] as u32;
        let b = rgba[i * 4 + 2] as u32;
        out[i] = ((r * 77 + g * 150 + b * 29) >> 8) as u8;
    }
    out
}

// MARK: - Kit histograms (PlayerJerseySignature)

/// 15-bin hue/neutral histogram of RGB triples in 0…1 (12 hue bins + 3 neutral brightness bins), normalized.
#[wasm_bindgen]
pub fn jersey_histogram(colors: &[f32]) -> Vec<f32> {
    let mut histogram = [0f32; 15];
    for rgb in colors.chunks_exact(3) {
        let (r, g, b) = (rgb[0], rgb[1], rgb[2]);
        let high = r.max(g).max(b);
        let low = r.min(g).min(b);
        let delta = high - low;
        let saturation = if high > 0.0 { delta / high } else { 0.0 };
        if saturation < 0.2 || high < 0.12 {
            let value = (high * 2.0).clamp(0.0, 2.0);
            let lower = (value.floor() as usize).min(2);
            let upper = (lower + 1).min(2);
            let fraction = value - lower as f32;
            histogram[12 + lower] += 1.0 - fraction;
            histogram[12 + upper] += fraction;
        } else {
            let mut hue = if high == r { (g - b) / delta } else if high == g { 2.0 + (b - r) / delta } else { 4.0 + (r - g) / delta };
            if hue < 0.0 { hue += 6.0; }
            let bin = hue * 2.0;
            let index = (bin.floor() as usize) % 12;
            let fraction = bin - bin.floor();
            histogram[index] += 1.0 - fraction;
            histogram[(index + 1) % 12] += fraction;
        }
    }
    let total = histogram.iter().sum::<f32>().max(1.0);
    histogram.iter().map(|v| v / total).collect()
}

/// Bhattacharyya coefficient of two normalized histograms.
#[wasm_bindgen]
pub fn histogram_similarity(a: &[f32], b: &[f32]) -> f32 {
    if a.len() != b.len() || a.is_empty() { return 0.0; }
    a.iter().zip(b).map(|(x, y)| (x * y).max(0.0).sqrt()).sum()
}

// MARK: - Camera feature registration

/// Harris-style corners of a luma image (0…1 floats) with equal spatial quotas: 8×6 cells, 3 per cell, skipping the
/// bottom tenth. Returns flat `[x0, y0, x1, y1, …]` pixel coordinates.
#[wasm_bindgen]
pub fn corners(values: &[f32], width: u32, height: u32) -> Vec<f32> {
    let (width, height) = (width as usize, height as usize);
    if values.len() < width * height || width < 20 || height < 20 { return Vec::new(); }
    let mut result = Vec::with_capacity(48 * 2);
    for row in 0..6 {
        for column in 0..8 {
            let min_x = 8.max(column * width / 8);
            let max_x = (width - 8).min((column + 1) * width / 8);
            let min_y = 8.max(row * height * 9 / 60);
            let max_y = (height - 8).min((row + 1) * height * 9 / 60);
            let mut candidates: Vec<(f32, usize, usize)> = Vec::new();
            let mut y = min_y;
            while y < max_y {
                let mut x = min_x;
                while x < max_x {
                    let (mut xx, mut yy, mut xy) = (0f32, 0f32, 0f32);
                    for dy in -1i32..=1 {
                        for dx in -1i32..=1 {
                            let i = ((y as i32 + dy) as usize) * width + (x as i32 + dx) as usize;
                            let gx = values[i + 1] - values[i - 1];
                            let gy = values[i + width] - values[i - width];
                            xx += gx * gx; yy += gy * gy; xy += gx * gy;
                        }
                    }
                    let strength = (xx + yy - ((xx - yy) * (xx - yy) + 4.0 * xy * xy).sqrt()) / 2.0;
                    if strength > 0.012 { candidates.push((strength, x, y)); }
                    x += 3;
                }
                y += 3;
            }
            candidates.sort_by(|a, b| b.0.partial_cmp(&a.0).unwrap_or(std::cmp::Ordering::Equal));
            let mut chosen: Vec<(f32, f32)> = Vec::new();
            for (_, x, y) in candidates {
                let (px, py) = (x as f32, y as f32);
                if chosen.iter().all(|(cx, cy)| ((cx - px).powi(2) + (cy - py).powi(2)).sqrt() > 16.0) {
                    chosen.push((px, py));
                    if chosen.len() == 3 { break; }
                }
            }
            for (x, y) in chosen { result.push(x); result.push(y); }
        }
    }
    result
}

/// Coarse-to-fine SAD block matching of `previous` in `current` (same size luma images). Returns `[dx, dy]` pixels, or
/// an empty vector when nothing could be compared.
#[wasm_bindgen]
pub fn translation(previous: &[f32], current: &[f32], width: u32, height: u32, maximum_fraction: f32) -> Vec<f32> {
    let (width, height) = (width as usize, height as usize);
    if previous.len() < width * height || current.len() < width * height || width < 20 || height < 20 { return Vec::new(); }
    let step = 1.max(width / 80);
    let sad = |dx: i32, dy: i32| -> f32 {
        let (mut sum, mut count) = (0f32, 0u32);
        let mut y = 8usize;
        while y + 8 < height {
            let mut x = 8usize;
            while x + 8 < width {
                let tx = x as i32 + dx;
                let ty = y as i32 + dy;
                if tx >= 0 && ty >= 0 && (tx as usize) < width && (ty as usize) < height {
                    sum += (previous[y * width + x] - current[ty as usize * width + tx as usize]).abs();
                    count += 1;
                }
                x += step;
            }
            y += step;
        }
        if count > 0 { sum / count as f32 } else { f32::INFINITY }
    };
    let radius_x = (width as f32 * maximum_fraction) as i32;
    let radius_y = (height as f32 * maximum_fraction) as i32;
    let mut best = (0i32, 0i32, sad(0, 0));
    let coarse = 1.max(width / 80) as i32;
    let mut dy = -radius_y;
    while dy <= radius_y {
        let mut dx = -radius_x;
        while dx <= radius_x {
            let value = sad(dx, dy);
            if value < best.2 { best = (dx, dy, value); }
            dx += coarse * 2;
        }
        dy += coarse * 2;
    }
    let mut refine = coarse;
    while refine >= 1 {
        let centre = best;
        let mut dy = centre.1 - refine * 2;
        while dy <= centre.1 + refine * 2 {
            let mut dx = centre.0 - refine * 2;
            while dx <= centre.0 + refine * 2 {
                let value = sad(dx, dy);
                if value < best.2 { best = (dx, dy, value); }
                dx += refine;
            }
            dy += refine;
        }
        if refine == 1 { break; }
        refine /= 2;
    }
    if !best.2.is_finite() { return Vec::new(); }
    vec![best.0 as f32, best.1 as f32]
}

/// Least-squares homography (h33 = 1) from `[x, y, u, v, …]` correspondences with pivoted elimination. Empty when
/// degenerate.
#[wasm_bindgen]
pub fn fit_homography(matches: &[f64]) -> Vec<f64> {
    let mut system = [[0f64; 9]; 8];
    for m in matches.chunks_exact(4) {
        let (x, y, u, v) = (m[0], m[1], m[2], m[3]);
        let rows = [([x, y, 1.0, 0.0, 0.0, 0.0, -u * x, -u * y], u), ([0.0, 0.0, 0.0, x, y, 1.0, -v * x, -v * y], v)];
        for (row, value) in rows {
            for i in 0..8 {
                for j in 0..8 { system[i][j] += row[i] * row[j]; }
                system[i][8] += row[i] * value;
            }
        }
    }
    match solve_normal(&mut system, 1e-10) {
        Some(mut h) => { h.push(1.0); h }
        None => Vec::new(),
    }
}

fn solve_normal(system: &mut [[f64; 9]; 8], threshold: f64) -> Option<Vec<f64>> {
    for column in 0..8 {
        let mut pivot = column;
        for r in column + 1..8 {
            if system[r][column].abs() > system[pivot][column].abs() { pivot = r; }
        }
        if system[pivot][column].abs() <= threshold { return None; }
        system.swap(column, pivot);
        let divisor = system[column][column];
        for j in column..9 { system[column][j] /= divisor; }
        for r in 0..8 {
            if r == column { continue; }
            let factor = system[r][column];
            if factor == 0.0 { continue; }
            for j in column..9 { system[r][j] -= factor * system[column][j]; }
        }
    }
    let result: Vec<f64> = system.iter().map(|row| row[8]).collect();
    if result.iter().all(|v| v.is_finite()) { Some(result) } else { None }
}

// MARK: - Pitch marking evidence (PitchRegistration.Evidence)

/// Whiteness (0…255) followed by turf (0/1) maps, each `width * height` bytes, packed into one buffer.
#[wasm_bindgen]
pub fn marking_evidence(rgba: &[u8], width: u32, height: u32) -> Vec<u8> {
    let n = (width * height) as usize;
    let mut out = vec![0u8; 2 * n];
    for index in 0..n.min(rgba.len() / 4) {
        let r = rgba[index * 4] as i32;
        let g = rgba[index * 4 + 1] as i32;
        let b = rgba[index * 4 + 2] as i32;
        if g > 45 && g * 100 > r * 94 && g * 100 > b * 135 { out[n + index] = 1; }
        if !(r * 10 > g * 8 && b * 20 > g * 13) { continue; }
        let value = r.min(g).min(b) * 2 - r.max(g).max(b);
        if value > 0 { out[index] = value.min(255) as u8; }
    }
    out
}

// MARK: - Hough line segments (FieldLineDetection)

/// Straight white marking segments with turf on both sides. Input is RGBA at working resolution (≤640 wide);
/// output is flat `[x0, y0, x1, y1, …]` normalized to the image, at most 8 segments.
#[wasm_bindgen]
pub fn hough_segments(rgba: &[u8], width: u32, height: u32) -> Vec<f32> {
    let (width, height) = (width as usize, height as usize);
    if width <= 16 || height <= 16 || rgba.len() < width * height * 4 { return Vec::new(); }
    let rgb = |x: usize, y: usize| -> (f64, f64, f64) {
        let i = (y * width + x) * 4;
        (rgba[i] as f64, rgba[i + 1] as f64, rgba[i + 2] as f64)
    };
    let turf = |x: i64, y: i64| -> bool {
        if x < 0 || y < 0 || x as usize >= width || y as usize >= height { return false; }
        let (r, g, b) = rgb(x as usize, y as usize);
        g > 45.0 && g > r * 0.94 && g > b * 1.35
    };
    let mut points: Vec<(f64, f64)> = Vec::new();
    for y in 6..height - 6 {
        for x in 6..width - 6 {
            let (r, g, b) = rgb(x, y);
            if !((r + g + b) / 3.0 > 100.0 && r > g * 0.72 && b > g * 0.53) { continue; }
            let neighbours = [(x as i64 - 5, y as i64), (x as i64 + 5, y as i64), (x as i64, y as i64 - 5), (x as i64, y as i64 + 5)];
            let grass: Vec<(i64, i64)> = neighbours.iter().copied().filter(|(nx, ny)| turf(*nx, *ny)).collect();
            if grass.len() < 2 { continue; }
            let background: f64 = grass.iter().map(|(nx, ny)| { let (nr, ng, nb) = rgb(*nx as usize, *ny as usize); (nr + ng + nb) / 3.0 }).sum::<f64>() / grass.len() as f64;
            if (r + g + b) / 3.0 > background + 16.0 { points.push((x as f64, y as f64)); }
        }
    }
    if points.len() < 30 { return Vec::new(); }
    let radius = ((width * width + height * height) as f64).sqrt().ceil() as i64;
    let bins = (radius * 2 + 1) as usize;
    let cosines: Vec<f64> = (0..180).map(|a| (a as f64 * std::f64::consts::PI / 180.0).cos()).collect();
    let sines: Vec<f64> = (0..180).map(|a| (a as f64 * std::f64::consts::PI / 180.0).sin()).collect();
    let mut votes = vec![0i32; 180 * bins];
    for angle in 0..180 {
        for (px, py) in &points {
            let rho = (px * cosines[angle] + py * sines[angle]).round() as i64 + radius;
            votes[angle * bins + rho as usize] += 1;
        }
    }
    let mut peaks: Vec<usize> = (0..votes.len()).filter(|i| votes[*i] >= 35).collect();
    peaks.sort_by(|a, b| votes[*b].cmp(&votes[*a]));
    let mut result: Vec<[f64; 4]> = Vec::new();
    'peaks: for peak in peaks.into_iter().take(160) {
        let angle = peak / bins;
        let rho = (peak % bins) as f64 - radius as f64;
        let (nx, ny) = (cosines[angle], sines[angle]);
        let (dx, dy) = (-ny, nx);
        let mut support: Vec<f64> = points.iter().filter(|(px, py)| (px * nx + py * ny - rho).abs() < 1.3).map(|(px, py)| px * dx + py * dy).collect();
        support.sort_by(|a, b| a.partial_cmp(b).unwrap_or(std::cmp::Ordering::Equal));
        let Some(&first) = support.first() else { continue };
        let mut runs: Vec<(f64, f64, usize)> = Vec::new();
        let (mut start, mut previous, mut count) = (first, first, 0usize);
        for position in support {
            if position - previous > 10.0 { runs.push((start, previous, count)); start = position; count = 0; }
            previous = position; count += 1;
        }
        runs.push((start, previous, count));
        runs.sort_by(|a, b| (b.1 - b.0).partial_cmp(&(a.1 - a.0)).unwrap_or(std::cmp::Ordering::Equal));
        for (low, high, n) in runs {
            let length = high - low;
            if !(length > width as f64 * 0.09 && n as f64 / length > 0.55) { continue; }
            let a = (nx * rho + dx * low, ny * rho + dy * low);
            let b = (nx * rho + dx * high, ny * rho + dy * high);
            let mut turf_samples = 0;
            for step in 0..20 {
                let t = low + length * (step as f64 + 0.5) / 20.0;
                let (x, y) = (nx * rho + dx * t, ny * rho + dy * t);
                if turf((x + nx * 5.0) as i64, (y + ny * 5.0) as i64) && turf((x - nx * 5.0) as i64, (y - ny * 5.0) as i64) { turf_samples += 1; }
            }
            if turf_samples < 13 { continue; }
            let duplicate = result.iter().any(|segment| {
                let (px, py) = (segment[0] * width as f64, segment[1] * height as f64);
                let (qx, qy) = (segment[2] * width as f64, segment[3] * height as f64);
                let along_normal = (qx - px) * nx + (qy - py) * ny;
                let parallel = along_normal.abs() / ((qx - px).hypot(qy - py)).max(1.0) < 0.18;
                let (pt, qt) = (px * dx + py * dy, qx * dx + qy * dy);
                let overlap_start = low.max(pt.min(qt));
                let overlap_end = high.min(pt.max(qt));
                if !(parallel && overlap_end > overlap_start && (qt - pt).abs() > 1.0) { return false; }
                let fraction = ((overlap_start + overlap_end) / 2.0 - pt) / (qt - pt);
                let (x, y) = (px + (qx - px) * fraction, py + (qy - py) * fraction);
                (x * nx + y * ny - rho).abs() < 5.0
            });
            if !duplicate { result.push([a.0 / width as f64, a.1 / height as f64, b.0 / width as f64, b.1 / height as f64]); }
            if result.len() == 8 { break 'peaks; }
        }
    }
    result.into_iter().flat_map(|s| s.into_iter().map(|v| v as f32)).collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn luma_of_white_is_white() {
        assert_eq!(rgba_to_luma(&[255, 255, 255, 255], 1, 1)[0], 255);
    }

    #[test]
    fn jersey_histograms_separate_kits_and_match_themselves() {
        let green: Vec<f32> = (0..120).flat_map(|_| [0.08f32, 0.72, 0.18]).collect();
        let blue: Vec<f32> = (0..120).flat_map(|_| [0.08f32, 0.18, 0.78]).collect();
        let g = jersey_histogram(&green);
        let b = jersey_histogram(&blue);
        assert!((g.iter().sum::<f32>() - 1.0).abs() < 1e-4);
        assert!(histogram_similarity(&g, &g) > 0.99);
        assert!(histogram_similarity(&g, &b) < 0.5);
    }

    #[test]
    fn homography_recovers_a_translation() {
        let mut matches = Vec::new();
        for (x, y) in [(0.1, 0.1), (0.9, 0.1), (0.9, 0.9), (0.1, 0.9), (0.5, 0.3)] {
            matches.extend_from_slice(&[x, y, x + 0.2, y - 0.1]);
        }
        let h = fit_homography(&matches);
        assert_eq!(h.len(), 9);
        assert!((h[2] - 0.2).abs() < 1e-9 && (h[5] + 0.1).abs() < 1e-9);
        assert!((h[0] - 1.0).abs() < 1e-9 && h[6].abs() < 1e-9);
    }

    #[test]
    fn translation_finds_a_known_shift() {
        let (width, height) = (160usize, 90usize);
        // Smooth, non-repeating texture: coarse-to-fine block matching assumes a smooth SAD landscape like real footage.
        let pattern = |x: usize, y: usize| -> f32 {
            let (fx, fy) = (x as f32, y as f32);
            0.5 + 0.2 * (fx * 0.21 + fy * 0.07).sin() + 0.15 * (fx * 0.045 - fy * 0.13).cos() + 0.1 * ((fx + fy) * 0.31).sin() + 0.05 * (fx * 0.011 * fy * 0.013).sin()
        };
        let previous: Vec<f32> = (0..height).flat_map(|y| (0..width).map(move |x| pattern(x, y))).collect();
        let current: Vec<f32> = (0..height).flat_map(|y| (0..width).map(move |x| pattern(x.saturating_sub(6), y.saturating_sub(3)))).collect();
        let shift = translation(&previous, &current, width as u32, height as u32, 0.35);
        assert_eq!(shift, vec![6.0, 3.0]);
    }

    #[test]
    fn corners_prefer_textured_cells_and_stay_bounded() {
        let (width, height) = (320usize, 180usize);
        let values: Vec<f32> = (0..height).flat_map(|y| (0..width).map(move |x| if (x / 12 + y / 12) % 2 == 0 { 1.0 } else { 0.0 })).collect();
        let found = corners(&values, width as u32, height as u32);
        assert!(found.len() >= 2 && found.len() <= 48 * 3 * 2, "found {} values", found.len());
        for pair in found.chunks_exact(2) {
            assert!(pair[0] >= 8.0 && pair[0] < width as f32 - 8.0, "x out of range: {pair:?}");
            assert!(pair[1] >= 8.0 && pair[1] < height as f32 * 0.9 + 1.0, "y out of range: {pair:?}");
        }
        let flat = vec![0.5f32; width * height];
        assert!(corners(&flat, width as u32, height as u32).is_empty());
    }

    #[test]
    fn marking_evidence_marks_white_paint_and_turf() {
        let out = marking_evidence(&[250, 250, 250, 255, 40, 140, 40, 255], 2, 1);
        assert!(out[0] > 200 && out[1] == 0);
        assert_eq!(out[2], 0);
        assert_eq!(out[3], 1);
    }

    #[test]
    fn hough_finds_a_white_line_on_turf() {
        let (width, height) = (200usize, 120usize);
        let mut rgba = vec![0u8; width * height * 4];
        for y in 0..height {
            for x in 0..width {
                let i = (y * width + x) * 4;
                let white = y >= 58 && y <= 61;
                let (r, g, b) = if white { (255, 255, 255) } else { (50, 130, 45) };
                rgba[i] = r; rgba[i + 1] = g; rgba[i + 2] = b; rgba[i + 3] = 255;
            }
        }
        let segments = hough_segments(&rgba, width as u32, height as u32);
        assert!(segments.len() >= 4, "expected at least one segment, got {segments:?}");
        assert!((segments[1] - 0.5).abs() < 0.03 && (segments[3] - 0.5).abs() < 0.03);
    }
}
