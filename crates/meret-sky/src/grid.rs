//! A uniform grid over star positions for lasso and hit tests.

use crate::inside;

pub struct Grid {
    min: [f32; 2],
    cell: f32,
    cols: usize,
    rows: usize,
    cells: Vec<Vec<u32>>,
    points: Vec<[f32; 2]>,
}

impl Grid {
    pub fn build(points: Vec<[f32; 2]>, cell: f32) -> Self {
        let (mut min, mut max) = ([f32::MAX; 2], [f32::MIN; 2]);
        for p in &points {
            for k in 0..2 {
                min[k] = min[k].min(p[k]);
                max[k] = max[k].max(p[k]);
            }
        }
        if points.is_empty() {
            min = [0.0; 2];
            max = [0.0; 2];
        }
        let cols = (((max[0] - min[0]) / cell) as usize + 1).max(1);
        let rows = (((max[1] - min[1]) / cell) as usize + 1).max(1);
        let mut cells = vec![Vec::new(); cols * rows];
        for (i, p) in points.iter().enumerate() {
            let (c, r) = (((p[0] - min[0]) / cell) as usize, ((p[1] - min[1]) / cell) as usize);
            cells[r.min(rows - 1) * cols + c.min(cols - 1)].push(i as u32);
        }
        Self { min, cell, cols, rows, cells, points }
    }

    /// Indices of the points inside `poly`.
    pub fn lasso(&self, poly: &[[f32; 2]]) -> Vec<u32> {
        if poly.len() < 3 {
            return vec![];
        }
        let (mut lo, mut hi) = ([f32::MAX; 2], [f32::MIN; 2]);
        for p in poly {
            for k in 0..2 {
                lo[k] = lo[k].min(p[k]);
                hi[k] = hi[k].max(p[k]);
            }
        }
        let cell_of = |v: f32, k: usize, n: usize| (((v - self.min[k]) / self.cell).max(0.0) as usize).min(n - 1);
        let (c0, c1) = (cell_of(lo[0], 0, self.cols), cell_of(hi[0], 0, self.cols));
        let (r0, r1) = (cell_of(lo[1], 1, self.rows), cell_of(hi[1], 1, self.rows));
        let mut out = vec![];
        for r in r0..=r1 {
            for c in c0..=c1 {
                for &i in &self.cells[r * self.cols + c] {
                    if inside(poly, self.points[i as usize]) {
                        out.push(i);
                    }
                }
            }
        }
        out.sort_unstable();
        out
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn lasso_finds_what_is_inside() {
        let pts: Vec<[f32; 2]> = (0..100).map(|i| [(i % 10) as f32, (i / 10) as f32]).collect();
        let g = Grid::build(pts, 2.0);
        let square = [[1.5, 1.5], [4.5, 1.5], [4.5, 4.5], [1.5, 4.5]];
        let got = g.lasso(&square);
        assert_eq!(got.len(), 9);
        assert!(got.contains(&22) && got.contains(&44) && !got.contains(&11));
    }
}
