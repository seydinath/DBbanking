-- University Information System (Simulation)

-- Step 2 - SQL Table Creation
CREATE TABLE students (
  student_id   SERIAL PRIMARY KEY,
  name         TEXT NOT NULL,
  email        TEXT NOT NULL UNIQUE,
  age          INT NOT NULL CHECK (age > 17)
);

CREATE TABLE instructors (
  instructor_id SERIAL PRIMARY KEY,
  name          TEXT NOT NULL,
  department    TEXT NOT NULL
);

CREATE TABLE courses (
  course_id     SERIAL PRIMARY KEY,
  title         TEXT NOT NULL,
  credits       INT NOT NULL CHECK (credits > 0),
  instructor_id INT NOT NULL REFERENCES instructors(instructor_id)
);

CREATE TABLE enrollments (
  student_id INT NOT NULL REFERENCES students(student_id) ON DELETE CASCADE,
  course_id  INT NOT NULL REFERENCES courses(course_id) ON DELETE CASCADE,
  grade      TEXT CHECK (grade IN ('A','B','C','D','F','I')),
  PRIMARY KEY (student_id, course_id)
);

-- Step 3 - Insert Sample Data
INSERT INTO students (name, email, age) VALUES
  ('Amal Ben Ali', 'amal.benali@uni.tn', 20),
  ('Karim Mansour', 'karim.mansour@uni.tn', 22),
  ('Noura Zahaf', 'noura.zahaf@uni.tn', 19);

INSERT INTO instructors (name, department) VALUES
  ('Dr. Salma Haddad', 'Computer Science'),
  ('Dr. Walid Trabelsi', 'Information Systems'),
  ('Dr. Hela Gharbi', 'Mathematics');

INSERT INTO courses (title, credits, instructor_id) VALUES
  ('Database Systems', 4, 2),
  ('Data Structures', 3, 1),
  ('Discrete Mathematics', 3, 3);

INSERT INTO enrollments (student_id, course_id, grade) VALUES
  (1, 1, 'A'),
  (1, 2, 'B'),
  (2, 1, 'C'),
  (3, 3, 'B');

-- Step 4 - Query Execution

-- Retrieve all students enrolled in the course "Database Systems"
SELECT s.student_id, s.name, s.email
FROM students s
JOIN enrollments e ON e.student_id = s.student_id
JOIN courses c ON c.course_id = e.course_id
WHERE c.title = 'Database Systems';

-- List all courses along with the names of their instructors
SELECT c.course_id, c.title, c.credits, i.name AS instructor_name
FROM courses c
JOIN instructors i ON i.instructor_id = c.instructor_id
ORDER BY c.course_id;

-- Find students who are not enrolled in any course
SELECT s.student_id, s.name, s.email
FROM students s
LEFT JOIN enrollments e ON e.student_id = s.student_id
WHERE e.student_id IS NULL;

-- Update the email address of a student (example: student_id = 2)
UPDATE students
SET email = 'karim.mansour2@uni.tn'
WHERE student_id = 2;

-- Delete a course by its ID (example: course_id = 3)
DELETE FROM courses
WHERE course_id = 3;
