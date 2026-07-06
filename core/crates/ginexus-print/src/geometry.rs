//! The mesh gate — pure-Rust "CAD understanding" for the agent. Parses an STL and produces one
//! ModelReport JSON covering topology (watertight/manifold via edge pairing), metrics (signed
//! volume, bbox, surface area), and printability signals (steep downward-facing overhang area).
//! Every generated or downloaded model passes this gate BEFORE slicing; the agent reasons over
//! the report, never over raw geometry.

use serde::{Deserialize, Serialize};
use std::collections::HashMap;
use std::path::Path;

/// Faces whose normal points further down than this many degrees from horizontal count as
/// overhang surface needing supports (45° is the classic printability threshold).
const OVERHANG_DEG: f64 = 45.0;

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ModelReport {
    pub file: String,
    pub triangles: usize,
    pub vertices: usize,
    /// Every edge shared by exactly two faces (no holes, no fins) — required for slicing.
    pub watertight: bool,
    /// Edges belonging to ≠2 faces; 0 for a printable solid.
    pub boundary_edges: usize,
    pub non_manifold_edges: usize,
    /// Millimetres (STL is unitless; mm is the 3D-printing convention).
    pub bbox_mm: [f64; 3],
    pub volume_mm3: f64,
    pub surface_area_mm2: f64,
    /// Fraction (0–1) of total surface area facing steeply downward (needs supports).
    pub overhang_area_fraction: f64,
    /// Human-readable verdict lines the agent can quote.
    pub notes: Vec<String>,
}

impl ModelReport {
    /// The gate verdict: sliceable solid or not.
    pub fn passes(&self) -> bool {
        self.watertight && self.volume_mm3 > 0.0 && self.triangles > 0
    }
}

fn key(v: &stl_io::Vertex) -> [u32; 3] {
    // Bit-exact vertex welding: STL repeats vertices per-triangle; identical floats weld.
    [v[0].to_bits(), v[1].to_bits(), v[2].to_bits()]
}

/// Analyze an STL file into a ModelReport.
pub fn analyze_stl(path: &Path) -> Result<ModelReport, String> {
    let mut f = std::fs::File::open(path).map_err(|e| format!("open: {e}"))?;
    let mesh = stl_io::read_stl(&mut f).map_err(|e| format!("not a readable STL: {e}"))?;

    let tri_count = mesh.faces.len();
    if tri_count == 0 {
        return Err("STL contains no triangles".into());
    }

    // Weld vertices bit-exactly, then count how many faces share each undirected edge.
    let mut weld: HashMap<[u32; 3], usize> = HashMap::new();
    let mut vid = vec![0usize; mesh.vertices.len()];
    for (i, v) in mesh.vertices.iter().enumerate() {
        let next = weld.len();
        let id = *weld.entry(key(v)).or_insert(next);
        vid[i] = id;
    }
    let mut edges: HashMap<(usize, usize), u32> = HashMap::new();
    for face in &mesh.faces {
        let [a, b, c] = [vid[face.vertices[0]], vid[face.vertices[1]], vid[face.vertices[2]]];
        for (u, v) in [(a, b), (b, c), (c, a)] {
            let e = if u < v { (u, v) } else { (v, u) };
            *edges.entry(e).or_insert(0) += 1;
        }
    }
    let boundary_edges = edges.values().filter(|&&n| n == 1).count();
    let non_manifold_edges = edges.values().filter(|&&n| n > 2).count();
    let watertight = boundary_edges == 0 && non_manifold_edges == 0;

    // Metrics in one pass over faces.
    let (mut vol6, mut area, mut overhang_area) = (0.0f64, 0.0f64, 0.0f64);
    let (mut min, mut max) = ([f64::MAX; 3], [f64::MIN; 3]);
    let cos_limit = (90.0 - OVERHANG_DEG).to_radians().cos(); // normal_z < -cos_limit ⇒ overhang
    for face in &mesh.faces {
        let p: Vec<[f64; 3]> = face
            .vertices
            .iter()
            .map(|&i| {
                let v = &mesh.vertices[i];
                [f64::from(v[0]), f64::from(v[1]), f64::from(v[2])]
            })
            .collect();
        for q in &p {
            for k in 0..3 {
                min[k] = min[k].min(q[k]);
                max[k] = max[k].max(q[k]);
            }
        }
        let u = [p[1][0] - p[0][0], p[1][1] - p[0][1], p[1][2] - p[0][2]];
        let w = [p[2][0] - p[0][0], p[2][1] - p[0][1], p[2][2] - p[0][2]];
        let cross =
            [u[1] * w[2] - u[2] * w[1], u[2] * w[0] - u[0] * w[2], u[0] * w[1] - u[1] * w[0]];
        let a2 = (cross[0] * cross[0] + cross[1] * cross[1] + cross[2] * cross[2]).sqrt();
        let tri_area = a2 / 2.0;
        area += tri_area;
        // Signed volume of tetrahedron (origin, p0, p1, p2).
        vol6 += p[0][0] * (p[1][1] * p[2][2] - p[1][2] * p[2][1])
            - p[0][1] * (p[1][0] * p[2][2] - p[1][2] * p[2][0])
            + p[0][2] * (p[1][0] * p[2][1] - p[1][1] * p[2][0]);
        if a2 > 0.0 {
            let nz = cross[2] / a2; // geometric normal from winding (ignore stored normals)
            if nz < -cos_limit {
                overhang_area += tri_area;
            }
        }
    }
    let volume = (vol6 / 6.0).abs();
    let bbox = [max[0] - min[0], max[1] - min[1], max[2] - min[2]];
    let overhang_frac = if area > 0.0 { overhang_area / area } else { 0.0 };

    let mut notes = Vec::new();
    if watertight {
        notes.push("watertight manifold solid — sliceable".into());
    } else {
        notes.push(format!(
            "NOT watertight: {boundary_edges} boundary edge(s), {non_manifold_edges} non-manifold edge(s) — repair before slicing"
        ));
    }
    // Overhang note: the bottom face of any flat-bottomed part faces straight down, so a small
    // fraction is normal; flag only when meaningful.
    if overhang_frac > 0.05 {
        notes.push(format!(
            "{:.0}% of surface faces steeply downward (>{OVERHANG_DEG:.0}° overhang) — supports likely required",
            overhang_frac * 100.0
        ));
    }
    if bbox.iter().any(|&d| d > 300.0) {
        notes.push("larger than 300 mm on an axis — check build volume".into());
    }

    Ok(ModelReport {
        file: path.to_string_lossy().to_string(),
        triangles: tri_count,
        vertices: weld.len(),
        watertight,
        boundary_edges,
        non_manifold_edges,
        bbox_mm: bbox,
        volume_mm3: volume,
        surface_area_mm2: area,
        overhang_area_fraction: overhang_frac,
        notes,
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use stl_io::{Normal, Triangle, Vertex};

    /// Axis-aligned unit-ish cube (size mm), 12 triangles, correct outward winding.
    fn cube_triangles(s: f32) -> Vec<Triangle> {
        let v = |x: f32, y: f32, z: f32| Vertex::new([x, y, z]);
        let quad = |a: Vertex, b: Vertex, c: Vertex, d: Vertex| {
            vec![
                Triangle { normal: Normal::new([0.0, 0.0, 0.0]), vertices: [a, b, c] },
                Triangle { normal: Normal::new([0.0, 0.0, 0.0]), vertices: [a, c, d] },
            ]
        };
        let (p000, p100, p110, p010) = (v(0., 0., 0.), v(s, 0., 0.), v(s, s, 0.), v(0., s, 0.));
        let (p001, p101, p111, p011) = (v(0., 0., s), v(s, 0., s), v(s, s, s), v(0., s, s));
        let mut t = Vec::new();
        t.extend(quad(p000, p010, p110, p100)); // bottom (normal -z)
        t.extend(quad(p001, p101, p111, p011)); // top (+z)
        t.extend(quad(p000, p100, p101, p001)); // front (-y)
        t.extend(quad(p100, p110, p111, p101)); // right (+x)
        t.extend(quad(p110, p010, p011, p111)); // back (+y)
        t.extend(quad(p010, p000, p001, p011)); // left (-x)
        t
    }

    fn write_stl(name: &str, tris: &[Triangle]) -> std::path::PathBuf {
        let p = std::env::temp_dir().join(name);
        let mut f = std::fs::File::create(&p).unwrap();
        stl_io::write_stl(&mut f, tris.iter()).unwrap();
        p
    }

    #[test]
    fn cube_passes_the_gate() {
        let p = write_stl("gx-geom-cube.stl", &cube_triangles(10.0));
        let r = analyze_stl(&p).expect("analyze");
        assert!(r.watertight, "cube must be watertight: {r:?}");
        assert!(r.passes());
        assert_eq!(r.triangles, 12);
        assert_eq!(r.vertices, 8);
        assert!((r.volume_mm3 - 1000.0).abs() < 1.0, "vol {}", r.volume_mm3);
        assert!((r.surface_area_mm2 - 600.0).abs() < 1.0);
        assert!((r.bbox_mm[0] - 10.0).abs() < 1e-6);
        // Only the bottom face (1/6 of area) faces down.
        assert!((r.overhang_area_fraction - 1.0 / 6.0).abs() < 0.01);
        let _ = std::fs::remove_file(&p);
    }

    #[test]
    fn open_mesh_fails_the_gate() {
        let mut tris = cube_triangles(10.0);
        tris.pop(); // knock a hole in it
        let p = write_stl("gx-geom-open.stl", &tris);
        let r = analyze_stl(&p).expect("analyze");
        assert!(!r.watertight);
        assert!(r.boundary_edges > 0);
        assert!(!r.passes());
        assert!(r.notes[0].contains("NOT watertight"));
        let _ = std::fs::remove_file(&p);
    }

    #[test]
    fn garbage_file_is_a_clean_error() {
        let p = std::env::temp_dir().join("gx-geom-garbage.stl");
        std::fs::write(&p, b"this is not an stl").unwrap();
        assert!(analyze_stl(&p).is_err());
        let _ = std::fs::remove_file(&p);
    }
}
